{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Module: TXG
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Emmanuel Denloye-Ito <emmanuel@kadena.io>
-- Stability: experimental
--
-- TODO
--

module TXG ( main ) where

import BasePrelude hiding (loop, rotate, timeout, (%))

import Configuration.Utils hiding (Error, Lens', (<.>))

import Control.Concurrent.Async (mapConcurrently_)
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM.TVar (modifyTVar')
import Control.Lens hiding (op, (.=), (|>))
import Control.Monad.Except
import Control.Monad.Reader hiding (local)
import Control.Monad.State.Strict

import qualified Data.HashSet as HS
import qualified Data.List.NonEmpty as NEL
import Data.LogMessage
import Data.Map (Map)
import qualified Data.Map as M
import Data.Sequence.NonEmpty (NESeq(..))
import qualified Data.Sequence.NonEmpty as NES
import Data.Text (Text)
import qualified Data.Text as T

import Fake (fake, generate)

import Network.HTTP.Client hiding (Proxy, host)

import Servant.API
import Servant.Client

import System.Logger hiding (StdOut)
import System.Random
import System.Random.MWC (createSystemRandom, uniformR)
import System.Random.MWC.Distributions (normal)

import Text.Pretty.Simple (pPrintNoColor)

-- PACT
import Pact.ApiReq
import Pact.Parse (ParsedDecimal(..), ParsedInteger(..))
import Pact.Types.API
import qualified Pact.Types.ChainMeta as CM
import Pact.Types.Command (Command(..), RequestKey(..))
import Pact.Types.Crypto
import qualified Pact.Types.Hash as H

-- CHAINWEB
import Chainweb.ChainId
import Chainweb.Graph
import Chainweb.HostAddress
import Chainweb.Pact.RestAPI
import Chainweb.RestAPI.Utils
import Chainweb.Utils
import Chainweb.Version

import TXG.Simulate.Contracts.CoinContract
import qualified TXG.Simulate.Contracts.Common as Sim
import TXG.Simulate.Contracts.HelloWorld
import TXG.Simulate.Contracts.SimplePayments
import TXG.Simulate.Utils
import TXG.Types

import Utils.Logging
import qualified Utils.Logging.Config as U

---

generateDelay :: MonadIO m => TXG m Int
generateDelay = do
  distribution <- asks _confTimingDist
  gen <- gets _gsGen
  case distribution of
    Just (Gaussian gmean gvar) -> liftIO (truncate <$> normal gmean gvar gen)
    Just (Uniform ulow uhigh) -> liftIO (truncate <$> uniformR (ulow, uhigh) gen)
    Nothing -> error "generateDelay: impossible"

generateSimpleTransaction
  :: (MonadIO m, MonadLog SomeLogMessage m)
  => TXG m (ChainId, Command Text)
generateSimpleTransaction = do
  delay <- generateDelay
  stdgen <- liftIO newStdGen
  let (operandA, operandB, op) =
        flip evalState stdgen $ do
            a <- state $ randomR (1, 100 :: Integer)
            b <- state $ randomR (1, 100 :: Integer)
            ind <- state $ randomR (0, 2 :: Int)
            let operation = "+-*" !! ind
            pure (a, b, operation)
      theCode = "(" ++ [op] ++ " " ++ show operandA ++ " " ++ show operandB ++ ")"

  -- Choose a Chain to send this transaction to, and cycle the state.
  cid <- uses gsChains NES.head
  gsChains %= rotate

  -- Delay, so as not to hammer the network.
  liftIO $ threadDelay delay
  -- lift . logg Info . toLogMessage . T.pack $ "The delay is " ++ show delay ++ " seconds."
  lift . logg Info . toLogMessage . T.pack $ printf "Sending expression %s to %s" theCode (show cid)
  kps <- liftIO testSomeKeyPairs


  let publicmeta = CM.PublicMeta
                   (CM.ChainId $ chainIdToText cid)
                   ("sender" <> toText cid)
                   (ParsedInteger 100)
                   (ParsedDecimal 0.0001)
      theData = object ["test-admin-keyset" .= fmap formatB16PubKey kps]
  cmd <- liftIO $ mkExec theCode theData publicmeta kps Nothing
  pure (cid, cmd)

-- | O(1). The head value is moved to the end.
rotate :: NESeq a -> NESeq a
rotate (h :<|| rest) = rest :||> h

generateTransaction
  :: forall m. (MonadIO m, MonadLog SomeLogMessage m)
  => TXG m (ChainId, Command Text)
generateTransaction = do
  contractIndex <- liftIO $ randomRIO @Int (0, 0)

  -- Choose a Chain to send this transaction to, and cycle the state.
  cid <- uses gsChains NES.head
  gsChains %= rotate

  cks <- view confKeysets
  case M.lookup cid cks of
    Nothing -> error $ printf "%s is missing Accounts!" (show cid)
    Just accs -> do
      sample <- case contractIndex of
        0 -> coinContract cid accs
        1 -> liftIO $ generate fake >>= helloRequest
        2 -> payments cid accs
        _ -> error "No contract here"
      generateDelay >>= liftIO . threadDelay
      pure (cid, sample)
  where
    coinContract
      :: ChainId
      -> Map Sim.Account (Map Sim.ContractName [SomeKeyPair])
      -> TXG m (Command Text)
    coinContract cid accs = do
      case traverse (M.lookup (Sim.ContractName "coin")) accs of
        Nothing -> error "Some `Account` is missing a Coin Contract"
        Just coinaccts -> liftIO $ do
          coinContractRequest <- mkRandomCoinContractRequest coinaccts >>= generate
          createCoinContractRequest (Sim.makeMeta cid) coinContractRequest

    payments
      :: ChainId
      -> Map Sim.Account (Map Sim.ContractName [SomeKeyPair])
      -> TXG m (Command Text)
    payments cid accs = do
      case traverse (M.lookup (Sim.ContractName "payment")) accs of
        Nothing -> error "Some `Account` is missing Payment contracts"
        Just paymentAccts -> liftIO $ do
          paymentsRequest <- mkRandomSimplePaymentRequest paymentAccts >>= generate
          case paymentsRequest of
            SPRequestPay fromAccount _ _ -> case M.lookup fromAccount paymentAccts of
              Nothing ->
                error "This account does not have an associated keyset!"
              Just keyset ->
                createSimplePaymentRequest (Sim.makeMeta cid) paymentsRequest $ Just keyset
            SPRequestGetBalance _account ->
              createSimplePaymentRequest (Sim.makeMeta cid) paymentsRequest Nothing
            _ -> error "SimplePayments.CreateAccount code generation not supported"


sendTransaction
  :: MonadIO m
  => ChainId
  -> Command Text
  -> TXG m (Either ClientError RequestKeys)
sendTransaction cid cmd = do
  TXGConfig _ _ cenv v <- ask
  liftIO $ runClientM (send v cid $ SubmitBatch [cmd]) cenv

loop
  :: (MonadIO m, MonadLog SomeLogMessage m)
  => TXG m (ChainId, Command Text)
  -> TQueue Text
  -> TXG m ()
loop f tq = do
  (cid, transaction) <- f
  requestKeys <- sendTransaction cid transaction
  countTV <- gets _gsCounter
  liftIO . atomically $ modifyTVar' countTV (+ 1)
  count <- liftIO $ readTVarIO countTV
  liftIO . atomically . writeTQueue tq $ "Transaction count: " <> sshow count

  case requestKeys of
    Left servantError -> lift . logg Error $ toLogMessage (sshow servantError :: Text)
    Right _ -> pure ()

  logs <- liftIO . atomically $ flushTQueue tq
  lift $ traverse_ (logg Info . toLogMessage) logs
  loop f tq

type ContractLoader = CM.PublicMeta -> [SomeKeyPair] -> IO (Command Text)

loadContracts :: ScriptConfig -> HostAddress -> [ContractLoader] -> IO ()
loadContracts config host contractLoaders = do
  TXGConfig _ _ ce v <- mkTXGConfig Nothing config host
  forM_ (_nodeChainIds config) $ \cid -> do
    let !meta = Sim.makeMeta cid
    ts <- testSomeKeyPairs
    contracts <- traverse (\f -> f meta ts) contractLoaders
    pollresponse <- runExceptT $ do
      rkeys <- ExceptT $ runClientM (send v cid $ SubmitBatch contracts) ce
      ExceptT $ runClientM (poll v cid . Poll $ _rkRequestKeys rkeys) ce
    withConsoleLogger Info . logg Info $ sshow pollresponse

sendTransactions
  :: ScriptConfig
  -> HostAddress
  -> TVar TXCount
  -> TimingDistribution
  -> LoggerT SomeLogMessage IO ()
sendTransactions config host tv distribution = do
  cfg@(TXGConfig _ _ ce v) <- liftIO $ mkTXGConfig (Just distribution) config host

  let chains = maybe (versionChains $ _nodeVersion config) NES.fromList
               . NEL.nonEmpty
               $ _nodeChainIds config

  accountMap <- fmap (M.fromList . toList) . forM chains $ \cid -> do
    let !meta = Sim.makeMeta cid
    (paymentKS, paymentAcc) <- liftIO $ unzip <$> Sim.createPaymentsAccounts meta
    (coinKS, coinAcc) <- liftIO $ unzip <$> Sim.createCoinAccounts meta
    pollresponse <- liftIO . runExceptT $ do
      rkeys <- ExceptT $ runClientM (send v cid . SubmitBatch $ paymentAcc ++ coinAcc) ce
      ExceptT $ runClientM (poll v cid . Poll $ _rkRequestKeys rkeys) ce
    case pollresponse of
      Left e -> logg Error $ toLogMessage (sshow e :: Text)
      Right _ -> pure ()
    let accounts = buildGenAccountsKeysets Sim.accountNames paymentKS coinKS
    pure (cid, accounts)

  logg Info $ toLogMessage ("Real Transactions: Transactions are being generated" :: Text)

  -- Set up values for running the effect stack.
  gen <- liftIO createSystemRandom
  tq  <- liftIO newTQueueIO
  let act = loop generateTransaction tq
      env = set confKeysets accountMap cfg
      stt = TXGState gen tv chains

  evalStateT (runReaderT (runTXG act) env) stt
  where
    buildGenAccountsKeysets
      :: [Sim.Account]
      -> [[SomeKeyPair]]
      -> [[SomeKeyPair]]
      -> Map Sim.Account (Map Sim.ContractName [SomeKeyPair])
    buildGenAccountsKeysets accs pks cks = M.fromList $ zipWith3 go accs pks cks

    go :: Sim.Account
       -> [SomeKeyPair]
       -> [SomeKeyPair]
       -> (Sim.Account, Map Sim.ContractName [SomeKeyPair])
    go name pks cks = (name, M.fromList [ps, cs])
      where
        ps = (Sim.ContractName "payment", pks)
        cs = (Sim.ContractName "coin", cks)

versionChains :: ChainwebVersion -> NESeq ChainId
versionChains = NES.fromList . NEL.fromList . HS.toList . graphChainIds . _chainGraph

sendSimpleExpressions
  :: ScriptConfig
  -> HostAddress
  -> TVar TXCount
  -> TimingDistribution
  -> LoggerT SomeLogMessage IO ()
sendSimpleExpressions config host tv distribution = do
  logg Info $ toLogMessage ("Simple Expressions: Transactions are being generated" :: Text)
  gencfg <- lift $ mkTXGConfig (Just distribution) config host

  -- Set up values for running the effect stack.
  gen <- liftIO createSystemRandom
  tq  <- liftIO newTQueueIO
  let chs = maybe (versionChains $ _nodeVersion config) NES.fromList
             . NEL.nonEmpty
             $ _nodeChainIds config
      stt = TXGState gen tv chs

  evalStateT (runReaderT (runTXG (loop generateSimpleTransaction tq)) gencfg) stt

pollRequestKeys :: ScriptConfig -> HostAddress -> RequestKey -> IO ()
pollRequestKeys config host rkey = do
  TXGConfig _ _ ce v <- mkTXGConfig Nothing config host
  response <- runClientM (poll v cid $ Poll [rkey]) ce
  case response of
    Left _ -> putStrLn "Failure" >> exitWith (ExitFailure 1)
    Right (PollResponses a)
      | null a -> putStrLn "Failure no result returned" >> exitWith (ExitFailure 1)
      | otherwise -> print a >> exitSuccess
 where
    -- | It is assumed that the user has passed in a single, specific Chain that
    -- they wish to query.
    cid :: ChainId
    cid = fromMaybe (unsafeChainId 0) . listToMaybe $ _nodeChainIds config

listenerRequestKey :: ScriptConfig -> HostAddress -> ListenerRequest -> IO ()
listenerRequestKey config host listenerRequest = do
  TXGConfig _ _ ce v <- mkTXGConfig Nothing config host
  runClientM (listen v cid listenerRequest) ce >>= \case
    Left err -> print err >> exitWith (ExitFailure 1)
    Right r -> print (_arResult r) >> exitSuccess
  where
    -- | It is assumed that the user has passed in a single, specific Chain that
    -- they wish to query.
    cid :: ChainId
    cid = fromMaybe (unsafeChainId 0) . listToMaybe $ _nodeChainIds config

work :: ScriptConfig -> IO ()
work cfg = do
  mgr <- newManager defaultManagerSettings
  tv  <- newTVarIO 0
  withBaseHandleBackend "transaction-generator" mgr (defconfig ^. U.logConfigBackend)
    $ \baseBackend -> do
      let loggerBackend = logHandles [] baseBackend
      withLogger (U._logConfigLogger defconfig) loggerBackend $ \l ->
        mapConcurrently_ (\host -> runLoggerT (act tv host) l) $ _hostAddresses cfg
  where
    transH :: U.HandleConfig
    transH = _logHandleConfig cfg

    defconfig :: U.LogConfig
    defconfig =
      U.defaultLogConfig
      & U.logConfigLogger . loggerConfigThreshold .~ Info
      & U.logConfigBackend . U.backendConfigHandle .~ transH
      & U.logConfigTelemetryBackend . enableConfigConfig . U.backendConfigHandle .~ transH

    act :: TVar TXCount -> HostAddress -> LoggerT SomeLogMessage IO ()
    act tv host@(HostAddress h p) = localScope (\_ -> [(toText h, toText p)]) $ do
      case _scriptCommand cfg of
        DeployContracts [] -> liftIO $
          loadContracts cfg host $ initAdminKeysetContract : defaultContractLoaders
        DeployContracts cs -> liftIO $
          loadContracts cfg host $ initAdminKeysetContract : map createLoader cs
        RunStandardContracts distribution ->
          sendTransactions cfg host tv distribution
        RunSimpleExpressions distribution ->
          sendSimpleExpressions cfg host tv distribution
        PollRequestKeys rk -> liftIO $
          pollRequestKeys cfg host . RequestKey $ H.Hash rk
        ListenerRequestKey rk -> liftIO $
          listenerRequestKey cfg host . ListenerRequest . RequestKey $ H.Hash rk

main :: IO ()
main = runWithConfiguration mainInfo $ \config -> do
  let chains = graphChainIds . _chainGraph $ _nodeVersion config
      isMem  = all (`HS.member` chains) $ _nodeChainIds config
  unless isMem $ error $
    printf "Invalid chain %s for given version\n" (show $ _nodeChainIds config)
  pPrintNoColor config
  work config

mainInfo :: ProgramInfo ScriptConfig
mainInfo =
  programInfo
    "Chainweb-TransactionGenerator"
    scriptConfigParser
    defaultScriptConfig

-- TODO: This is here for when a user wishes to deploy their own
-- contract to chainweb. We will have to carefully consider which
-- chain we'd like to send the contract to.

-- TODO: This function should also incorporate a user's keyset as well
-- if it is given.
createLoader :: Sim.ContractName -> ContractLoader
createLoader (Sim.ContractName contractName) meta kp = do
  theCode <- readFile (contractName <> ".pact")
  adminKeyset <- testSomeKeyPairs
  -- TODO: theData may change later
  let theData = object
                ["admin-keyset" .= fmap formatB16PubKey adminKeyset
                , T.append (T.pack contractName) "-keyset" .= fmap formatB16PubKey kp]
  mkExec theCode theData meta adminKeyset Nothing

defaultContractLoaders :: [ContractLoader]
defaultContractLoaders = [helloWorldContractLoader , simplePaymentsContractLoader]
  -- Remember coin contract is already loaded.

api version chainid =
  case someChainwebVersionVal version of
    SomeChainwebVersionT (_ :: Proxy cv) ->
      case someChainIdVal chainid of
        SomeChainIdT (_ :: Proxy cid) ->
          client
            (Proxy :: Proxy (PactApi cv cid))

send :: ChainwebVersion -> ChainId -> SubmitBatch -> ClientM RequestKeys
send version chainid = go
  where
    go :<|> _ :<|> _ :<|> _ = api version chainid

poll :: ChainwebVersion -> ChainId -> Poll -> ClientM PollResponses
poll version chainid = go
  where
    _ :<|> go :<|> _ :<|> _ = api version chainid

listen :: ChainwebVersion -> ChainId -> ListenerRequest -> ClientM ApiResult
listen version chainid = go
  where
    _ :<|> _ :<|> go :<|> _ = api version chainid

---------------------------
-- FOR DEBUGGING IN GHCI --
---------------------------
_genapi2 :: ChainwebVersion -> ChainId -> Text
_genapi2 version chainid =
  case someChainwebVersionVal version of
    SomeChainwebVersionT (_ :: Proxy cv) ->
      case someChainIdVal chainid of
        SomeChainIdT (_ :: Proxy cid) ->
          let p = (Proxy :: Proxy ('ChainwebEndpoint cv :> ChainEndpoint cid :> "pact" :> Reassoc SendApi))
          in toUrlPiece $ safeLink (Proxy :: (Proxy (PactApi cv cid))) p
