{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Chainweb.Rosetta.RestAPI.Server
-- Copyright: Copyright © 2018 - 2020 Kadena LLC.
-- License: MIT
-- Maintainer: Colin Woodbury <colin@kadena.io>
-- Stability: experimental
--
--
module Chainweb.Rosetta.RestAPI.Server where

import Control.Error.Util
import Control.Lens ((^?))
import Control.Monad (void)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Data.Aeson
import Data.Bifunctor
import Data.Map (Map)
import Data.Decimal
import Data.CAS
import Data.List (foldl')
import Data.String
import Data.Proxy (Proxy(..))
import Data.Tuple.Strict (T2(..))
import Data.Word (Word64)

import qualified Data.ByteString.Short as BSS
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import qualified Data.Map as M
import qualified Data.Memory.Endian as BA
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Vector as V

import Numeric.Natural

import Pact.Types.ChainMeta (PublicMeta(..))
import Pact.Types.Command
import Pact.Types.Hash
import Pact.Types.Runtime (TxId(..), TxLog(..), Domain(..))
import Pact.Types.RPC
import Pact.Types.PactValue (PactValue(..))
import Pact.Types.Pretty (renderCompactText)
import Pact.Types.Exp (Literal(..))

import Rosetta

import Servant.API
import Servant.Server

-- internal modules

import Chainweb.BlockCreationTime (BlockCreationTime(..))
import Chainweb.BlockHash
import Chainweb.BlockHeader (BlockHeader(..))
import Chainweb.BlockHeader.Genesis (genesisBlockHeader)
import Chainweb.BlockHeight (BlockHeight(..))
import Chainweb.Chainweb.ChainResources (ChainResources(..))
import Chainweb.Cut
import Chainweb.CutDB
import Chainweb.HostAddress
import Chainweb.Mempool.Mempool
import Chainweb.Pact.RestAPI.Server
import Chainweb.Pact.Templates
import Chainweb.Pact.Service.Types (Domain'(..), BlockTxHistory(..))
import qualified Chainweb.RestAPI.NetworkID as ChainwebNetId
import Chainweb.RestAPI.Utils
import Chainweb.Rosetta.RestAPI
import Chainweb.Time
import Chainweb.Transaction (ChainwebTransaction)
import Chainweb.TreeDB (seekAncestor)
import Chainweb.Utils
import Chainweb.Utils.Paging
import Chainweb.Version
import Chainweb.WebPactExecutionService (PactExecutionService(..))

import P2P.Node.PeerDB
import P2P.Node.RestAPI.Server (peerGetHandler)
import P2P.Peer

---

rosettaServer
    :: forall cas a (v :: ChainwebVersionT)
    . ChainwebVersion
    -> [(ChainId, MempoolBackend ChainwebTransaction)]
    -> PeerDb
    -> CutDb cas
    -> [(ChainId, ChainResources a)]
    -> Server (RosettaApi v)
rosettaServer v ms peerDb cutDb cr =
    -- Account --
    accountBalanceH v cr
    -- Blocks --
    :<|> (const $ error "not yet implemented")
    :<|> (const $ error "not yet implemented")
    -- Construction --
    :<|> constructionMetadataH v
    :<|> constructionSubmitH v ms
    -- Mempool --
    :<|> mempoolTransactionH v ms
    :<|> mempoolH v ms
    -- Network --
    :<|> networkListH v
    :<|> networkOptionsH v
    :<|> (networkStatusH v cutDb peerDb)

someRosettaServer
    :: ChainwebVersion
    -> [(ChainId, MempoolBackend ChainwebTransaction)]
    -> PeerDb
    -> [(ChainId, ChainResources a)]
    -> CutDb cas
    -> SomeServer
someRosettaServer v@(FromSingChainwebVersion (SChainwebVersion :: Sing vT)) ms pdb crs cdb =
    SomeServer (Proxy @(RosettaApi vT)) $ rosettaServer v ms pdb cdb crs

--------------------------------------------------------------------------------
-- Account Handlers
accountBalanceH
    :: ChainwebVersion
    -> [(ChainId, ChainResources a)]
    -> AccountBalanceReq
    -> Handler AccountBalanceResp
accountBalanceH _ _ (AccountBalanceReq _ _ (Just _)) = throwRosetta RosettaHistBalCheckUnsupported
accountBalanceH _ _ (AccountBalanceReq _ (AccountId _ (Just _) _) _) = throwRosetta RosettaSubAcctUnsupported
accountBalanceH v crs (AccountBalanceReq net (AccountId acct _ _) _) =
  runExceptT work >>= either throwRosetta pure
  where
    readBal :: PactValue -> Maybe Decimal
    readBal (PLiteral (LDecimal d)) = Just d
    readBal _ = Nothing

    readBlock :: Maybe Value -> Maybe (Word64, T.Text)
    readBlock (Just (Object meta)) = do
      hi <- (HM.lookup "blockHeight" meta) >>= (hushResult . fromJSON)
      hsh <- (HM.lookup "prevBlockHash" meta) >>= (hushResult . fromJSON)
      pure $ (pred hi, hsh)
    readBlock _ = Nothing

    balCheckCmd :: ChainId -> IO (Command T.Text)
    balCheckCmd cid = do
      cmd <- mkCommand [] meta "nonce" Nothing rpc
      return $ T.decodeUtf8 <$> cmd
      where
        rpc = Exec $ ExecMsg code Null
        code = renderCompactText $
          app (bn "at")
            [ strLit "balance"
            , app (qn "coin" "details") [ strLit acct ]
            ]
        meta = PublicMeta
          (fromString $ show $ chainIdToText cid)
          "someSender"
          10000   -- gas limit
          0.0001  -- gas price
          300     -- ttl
          0       -- creation time

    work :: ExceptT RosettaFailure Handler AccountBalanceResp
    work = do
      cid <- validateNetwork v net
      cr <- lookup cid crs ?? RosettaInvalidChain
      cmd <- do
        c <- liftIO $ balCheckCmd cid
        (hush $ validateCommand c) ?? RosettaInvalidTx
      cRes <- do
        r <- liftIO $ _pactLocal (_chainResPact cr) cmd
        (hush r) ?? RosettaPactExceptionThrown
      let (PactResult pRes) = _crResult cRes
      pv <- (hush pRes) ?? RosettaPactErrorThrown
      balKDA <- readBal pv ?? RosettaExpectedBalDecimal
      (blockHeight, blockHash) <- (readBlock $ _crMetaData cRes) ?? RosettaInvalidResultMetaData

      pure $ AccountBalanceResp
        { _accountBalanceResp_blockId = BlockId blockHeight blockHash
        , _accountBalanceResp_balances = [ kdaToRosettaAmount balKDA ]
        , _accountBalanceResp_metadata = Nothing }

--------------------------------------------------------------------------------
-- Block Handlers

type CoinbaseCommandResult = CommandResult Hash
type AccountLog = (T.Text, Decimal, Value)
type UnindexedOperation = (Word64 -> Operation)

data RosettaOperationStatus =
    Successful
  | LockedInPact -- TODO: Think about.
  | UnlockedReverted -- TODO: Think about in case of rollback (same chain pacts)?
  | UnlockedTransfer -- TOOD: pacts finished, cross-chain?
  deriving (Enum, Bounded, Show)

data OperationType =
    CoinbaseReward
  | FundTx
  | GasPayment
  | TransferOrCreateAcct
  deriving (Enum, Bounded, Show)

blockH
    :: ChainwebVersion
    -> CutDb cas
    -> [(ChainId, ChainResources a)]
    -> BlockReq
    -> Handler BlockResp
blockH v cutDb crs (BlockReq net (PartialBlockId bheight bhash)) =
  runExceptT work >>= either throwRosetta pure
  where
    block :: BlockHeader -> [Transaction] -> Block
    block bh txs = Block
      { _block_blockId = blockId bh
      , _block_parentBlockId = parentBlockId bh
      , _block_timestamp = rosettaTimestamp bh
      , _block_transactions = txs
      , _block_metadata = Nothing
      }

    getTxLogs
        :: PactExecutionService
        -> BlockHeader
        -> ExceptT RosettaFailure Handler (Map TxId [AccountLog])
    getTxLogs cr bh = do
      (BlockTxHistory hist) <- do
        h <- liftIO $ (_pactBlockTxHistory cr) bh d
        (hush h) ?? RosettaPactExceptionThrown
      let histParsed = M.mapMaybe (mapM txLogToAccountInfo) hist
      if (M.size histParsed == M.size hist)
        then pure histParsed
        else throwError RosettaUnparsableTxLog
      where
        d = (Domain' (UserTables "coin_coin-table"))

    work :: ExceptT RosettaFailure Handler BlockResp
    work = do
      cid <- validateNetwork v net
      cr <- lookup cid crs ?? RosettaInvalidChain
      bh <- findBlockHeaderInCurrFork cutDb cid bheight bhash
      (coinbaseOut, txsOut) <- getBlockOutputs bh
      logs <- getTxLogs (_chainResPact cr) bh
      trans <- (getBlockTxs bh logs coinbaseOut txsOut) ?? RosettaMismatchTxLogs
      pure $ BlockResp
        { _blockResp_block = block bh trans
        , _blockResp_otherTransactions = Nothing
        }

getBlockTxs
    :: BlockHeader
    -> Map TxId [AccountLog]
    -> CoinbaseCommandResult
    -> [CommandResult Hash]
    -> Maybe [Transaction]
getBlockTxs bh logs coinbase rest
  | (_blockHeight bh == 0) = genesisTransactions logs rest
  | otherwise = nonGenesisTransactions logs coinbase rest


-- Genesis transactions have no coinbase or gas payments.
genesisTransactions
    :: Map TxId [AccountLog]
    -> [CommandResult Hash]
    -> Maybe [Transaction]
genesisTransactions logs crs = mapM f crs
  where
    makeOps tid l = indexedOperations $
      map (operation Successful TransferOrCreateAcct tid) l
    f cr = case (_crTxId cr) of
      Nothing -> pure $ rosettaTransaction cr []
      Just tid -> do
        l <- M.lookup tid logs
        pure $ rosettaTransaction cr $ makeOps tid l

-- The first transaction in non-genesis block is coinbase transaction.
-- For each following transaction, each has logs that fund the transaction,
-- interact with the coin contract (optional), and pay gas to the miner.
nonGenesisTransactions
    :: Map TxId [AccountLog]
    -> CoinbaseCommandResult
    -> [CommandResult Hash]
    -> Maybe [Transaction]
nonGenesisTransactions logs coinbaseCr crs = do
  coinbaseTid <- _crTxId coinbaseCr
  coinbaseTx <- do
    l <- M.lookup coinbaseTid logs
    let ops = indexedOperations $
          map (operation Successful CoinbaseReward coinbaseTid) l
    pure $ rosettaTransaction coinbaseCr ops
  (_,ts) <- foldl' acc (Just (succ coinbaseTid, [])) crs
  pure $ coinbaseTx : (reverse ts)

  where
    -- Allows for O(1) lookup by index
    --logsVector = V.fromList undefined -- TODO

    getLogs
        :: TxId
        -> OperationType
        -> Maybe (TxId, [UnindexedOperation])
    getLogs tid otype = do
      l <- M.lookup tid logs
      let opsF = map (operation Successful otype tid) l
      pure $ (succ tid, opsF)

    getTransferLogs
        :: TxId
        -> Maybe TxId
        -> Maybe (TxId, [UnindexedOperation])
    getTransferLogs expected actual
      | (actual == Just expected) = getLogs expected TransferOrCreateAcct
      | (actual == Nothing) = pure $ (expected, [])
      | otherwise = Nothing

    acc
        :: Maybe (TxId, [Transaction])
        -> CommandResult Hash
        -> Maybe (TxId, [Transaction])
    acc Nothing _ = Nothing
    acc (Just (tid,ts)) cr = do
      (transferTid, fund) <- getLogs tid FundTx
      (gasTid, transfer) <- getTransferLogs transferTid (_crTxId cr)
      (nextTid, gas) <- getLogs gasTid GasPayment
      let ops = indexedOperations $ fund ++ transfer ++ gas
          tx = rosettaTransaction cr ops
      pure $ (nextTid, tx:ts)


-- TODO: delete, similar to nonGenesisTransactions but uses vector.
_groupTxLogs
  :: V.Vector (TxId, [AccountLog])
  -> CoinbaseCommandResult
  -> [CommandResult Hash]
  -> Maybe [Transaction]
_groupTxLogs allLogs coinbaseRes allTxs = do
  coinbaseLogs <- allLogs V.!? 0
  coinbaseTx <- getCoinbaseRosettaTx coinbaseLogs coinbaseRes
  T2 _ ts <- foldl' acc (Just $ T2 1 []) allTxs
  -- when statement to check that went through all of txids
  pure (coinbaseTx : ts)
  where
    acc :: Maybe (T2 Int [Transaction]) -> CommandResult Hash -> Maybe (T2 Int [Transaction])
    acc Nothing _ = Nothing
    acc (Just (T2 idx txs)) res = do
      (transferIdx, fund) <- fundLogs idx
      (gasIdx, transfer) <- transferLogs transferIdx
      (nextIdx, gas) <- gasLogs gasIdx
      let ops = indexedOperations $ fund ++ transfer ++ gas
          tx' = rosettaTransaction res ops
      pure $ T2 nextIdx (tx' : txs) -- TODO: order?
      where
        fundLogs :: Int -> Maybe (Int, [UnindexedOperation])
        fundLogs i = do
          (tid, l) <- allLogs V.!? i
          let opsF = map (operation Successful FundTx tid) l
          pure (succ i, opsF)

        transferLogs :: Int -> Maybe (Int, [UnindexedOperation])
        transferLogs i = do
          (tid, l) <- allLogs V.!? i
          if (_crTxId res == Just tid)
            then pure $ (succ i, opsF l tid)
            else pure $ (i, [])
          where
            opsF li tid =
              map (operation Successful TransferOrCreateAcct tid) li

        gasLogs :: Int -> Maybe (Int, [UnindexedOperation])
        gasLogs i = do
          (tid, l) <- allLogs V.!? i
          let opF = map (operation Successful GasPayment tid) l
          pure (succ i, opF)

    getCoinbaseRosettaTx :: (TxId, [AccountLog]) -> CoinbaseCommandResult -> Maybe Transaction
    getCoinbaseRosettaTx (tid, [coinbaseLog]) cr
      | (Just tid == _crTxId cr) =
        let op = operation Successful CoinbaseReward tid coinbaseLog 0
        in pure $ rosettaTransaction cr [op]
      | otherwise = Nothing
    getCoinbaseRosettaTx _ _ = Nothing


-- TODO
getBlockOutputs
    :: BlockHeader
    -> ExceptT RosettaFailure Handler (CoinbaseCommandResult, [CommandResult Hash])
getBlockOutputs = undefined


findBlockHeaderInCurrFork
    :: CutDb cas
    -> ChainId
    -> Maybe Word64
    -- ^ Block Height
    -> Maybe T.Text
    -- ^ Block Hash
    -> ExceptT RosettaFailure Handler BlockHeader
findBlockHeaderInCurrFork cutDb cid someHeight someHash = do
  latestBlock <- getLatestBlockHeader cutDb cid
  chainDb <- (cutDb ^? cutDbBlockHeaderDb cid) ?? RosettaInvalidChain

  case (someHeight, someHash) of
    (Nothing, Nothing) -> pure latestBlock   -- assumes latest block at given chain id
    (Just hi, Nothing) -> byHeight chainDb latestBlock hi
    (Just hi, Just hsh) -> do
      bh <- byHeight chainDb latestBlock hi
      bhashExpected <- (blockHashFromText hsh) ?? RosettaUnparsableBlockHash
      if (_blockHash bh == bhashExpected)
        then pure bh
        else throwError RosettaMismatchBlockHashHeight
    (Nothing, Just hsh) -> do
      bhash <- (blockHashFromText hsh) ?? RosettaUnparsableBlockHash
      somebh <- liftIO $ (casLookup chainDb bhash)
      bh <- somebh ?? RosettaBlockHashNotFound
      isInCurrFork <- liftIO $ memberOfHeader cutDb cid bhash latestBlock
      if isInCurrFork
        then pure bh
        else throwError RosettaOrphanBlockHash
  where
    byHeight db latest hi = do
      somebh <- liftIO $ seekAncestor db latest (int hi)
      somebh ?? RosettaInvalidBlockHeight

--------------------------------------------------------------------------------
-- Construction Handlers

constructionMetadataH
    :: ChainwebVersion
    -> ConstructionMetadataReq
    -> Handler ConstructionMetadataResp
constructionMetadataH v (ConstructionMetadataReq net _) =
    runExceptT work >>= either throwRosetta pure
  where
    -- TODO: Extend as necessary.
    work :: ExceptT RosettaFailure Handler ConstructionMetadataResp
    work = do
        void $ validateNetwork v net
        pure $ ConstructionMetadataResp HM.empty

constructionSubmitH
    :: ChainwebVersion
    -> [(ChainId, MempoolBackend ChainwebTransaction)]
    -> ConstructionSubmitReq
    -> Handler ConstructionSubmitResp
constructionSubmitH v ms (ConstructionSubmitReq net tx) =
    runExceptT work >>= either throwRosetta pure
  where
    work :: ExceptT RosettaFailure Handler ConstructionSubmitResp
    work = do
        cid <- validateNetwork v net
        cmd <- command tx ?? RosettaUnparsableTx
        validated <- hoistEither . first (const RosettaInvalidTx) $ validateCommand cmd
        mp <- lookup cid ms ?? RosettaInvalidChain
        let !vec = V.singleton validated
        liftIO (mempoolInsertCheck mp vec) >>= hoistEither . first (const RosettaInvalidTx)
        liftIO (mempoolInsert mp UncheckedInsert vec)
        let rk = requestKeyToB16Text $ cmdToRequestKey validated
        pure $ ConstructionSubmitResp (TransactionId rk) Nothing

command :: T.Text -> Maybe (Command T.Text)
command = decodeStrict' . T.encodeUtf8

--------------------------------------------------------------------------------
-- Mempool Handlers

mempoolH
    :: ChainwebVersion
    -> [(ChainId, MempoolBackend a)]
    -> MempoolReq
    -> Handler MempoolResp
mempoolH v ms (MempoolReq net) = runExceptT work >>= either throwRosetta pure
  where
    work = do
        cid <- validateNetwork v net
        _ <- lookup cid ms ?? RosettaInvalidChain
        error "not yet implemented"  -- TODO!

mempoolTransactionH
    :: ChainwebVersion
    -> [(ChainId, MempoolBackend a)]
    -> MempoolTransactionReq
    -> Handler MempoolTransactionResp
mempoolTransactionH v ms mtr = runExceptT work >>= either throwRosetta pure
  where
    MempoolTransactionReq net (TransactionId ti) = mtr
    th = TransactionHash . BSS.toShort $ T.encodeUtf8 ti

    f :: LookupResult a -> Maybe MempoolTransactionResp
    f Missing = Nothing
    f (Pending _) = Just $ MempoolTransactionResp tx Nothing
      where
        tx = Transaction
          { _transaction_transactionId = TransactionId ti
          , _transaction_operations = [] -- TODO!
          , _transaction_metadata = Nothing
          }

    work :: ExceptT RosettaFailure Handler MempoolTransactionResp
    work = do
        cid <- validateNetwork v net
        mp <- lookup cid ms ?? RosettaInvalidChain
        lrs <- liftIO . mempoolLookup mp $ V.singleton th
        (lrs V.!? 0 >>= f) ?? RosettaMempoolBadTx

--------------------------------------------------------------------------------
-- Network Handlers

networkListH :: ChainwebVersion -> MetadataReq -> Handler NetworkListResp
networkListH v _ = pure $ NetworkListResp networkIds
  where
    -- Unique Rosetta network ids for each of the chainweb version's chain ids
    networkIds = map f (HS.toList (chainIds v))
    f :: ChainId -> NetworkId
    f cid =  NetworkId
      { _networkId_blockchain = "kadena"
      , _networkId_network = chainwebVersionToText v
      , _networkId_subNetworkId = Just (SubNetworkId (chainIdToText cid) Nothing)
      }

networkOptionsH :: ChainwebVersion -> NetworkReq -> Handler NetworkOptionsResp
networkOptionsH v (NetworkReq nid _) = runExceptT work >>= either throwRosetta pure
  where
    work :: ExceptT RosettaFailure Handler NetworkOptionsResp
    work = do
        void $ validateNetwork v nid
        pure $ NetworkOptionsResp version allow

    version = RosettaNodeVersion
      { _version_rosettaVersion = rosettaSpecVersion
      , _version_nodeVersion = chainwebNodeVersionHeaderValue
      , _version_middlewareVersion = Nothing
      , _version_metadata = Just $ HM.fromList metaPairs }

    -- TODO: Document this meta data
    metaPairs =
      [ "node-api-version" .= prettyApiVersion
      , "chainweb-version" .= chainwebVersionToText v ]

    allow = Allow
      { _allow_operationStatuses = [] -- TODO
      , _allow_operationTypes = [] -- TODO
      , _allow_errors = errExamples }

    errExamples :: [RosettaError]
    errExamples = map rosettaError [minBound .. maxBound]

networkStatusH
    :: ChainwebVersion
    -> CutDb cas
    -> PeerDb
    -> NetworkReq
    -> Handler NetworkStatusResp
networkStatusH v cutDb peerDb (NetworkReq nid _) =
    runExceptT work >>= either throwRosetta pure
  where
    work :: ExceptT RosettaFailure Handler NetworkStatusResp
    work = do
        cid <- validateNetwork v nid
        bh <- getLatestBlockHeader cutDb cid
        let genesisBh = genesisBlockHeader v cid
        -- TODO: Will this throw Handler error? How to wrap as Rosetta Error?
        peers <- lift $ _pageItems <$>
          peerGetHandler
          peerDb
          ChainwebNetId.CutNetwork
          -- TODO: document max number of peers returned
          (Just $ Limit maxRosettaNodePeerLimit)
          Nothing
        pure $ resp bh genesisBh peers

    resp :: BlockHeader -> BlockHeader -> [PeerInfo] -> NetworkStatusResp
    resp bh genesis ps = NetworkStatusResp
      { _networkStatusResp_currentBlockId = blockId bh
      , _networkStatusResp_currentBlockTimestamp = rosettaTimestamp bh
      , _networkStatusResp_genesisBlockId = blockId genesis
      , _networkStatusResp_peers = rosettaNodePeers ps
      }

    rosettaNodePeers :: [PeerInfo] -> [RosettaNodePeer]
    rosettaNodePeers ps = map f ps
      where
        f :: PeerInfo -> RosettaNodePeer
        f p = RosettaNodePeer
          { _peer_peerId = hostAddressToText $ _peerAddr p
          , _peer_metadata = Just . HM.fromList $ metaPairs p }

        -- TODO: document this meta data
        metaPairs :: PeerInfo -> [(T.Text, Value)]
        metaPairs p = addrPairs (_peerAddr p) ++ someCertPair (_peerId p)

        addrPairs :: HostAddress -> [(T.Text, Value)]
        addrPairs addr =
          [ "address_hostname" .= hostnameToText (_hostAddressHost addr)
          , "address_port" .= portToText (_hostAddressPort addr)
          -- TODO: document that port is string represation of Word16
          ]

        someCertPair :: Maybe PeerId -> [(T.Text, Value)]
        someCertPair (Just i) = ["certificate_id" .= i]
        someCertPair Nothing = []

--------------------------------------------------------------------------------
-- Utils

maxRosettaNodePeerLimit :: Natural
maxRosettaNodePeerLimit = 64

getLatestBlockHeader
    :: CutDb cas
    -> ChainId
    -> ExceptT RosettaFailure Handler BlockHeader
getLatestBlockHeader cutDb cid = do
  c <- liftIO $ _cut cutDb
  HM.lookup cid (_cutMap c) ?? RosettaInvalidChain


-- | If its the genesis block, Rosetta wants the parent block to be itself.
--   Otherwise, fetch the parent header from the block.
parentBlockId :: BlockHeader -> BlockId
parentBlockId bh
  | (_blockHeight bh == 0) = blockId bh  -- genesis
  | otherwise = parent
  where parent = BlockId
          { _blockId_index = _height (pred $ _blockHeight bh)
          , _blockId_hash = blockHashToText (_blockParent bh)
          }

blockId :: BlockHeader -> BlockId
blockId bh = BlockId
  { _blockId_index = _height (_blockHeight bh)
  , _blockId_hash = blockHashToText (_blockHash bh)
  }

txLogToAccountInfo :: TxLog Value -> Maybe AccountLog
txLogToAccountInfo (TxLog _ key (Object row)) = do
  guard :: Value <- (HM.lookup "guard" row) >>= (hushResult . fromJSON)
  (PLiteral (LDecimal bal)) <- (HM.lookup "balance" row) >>= (hushResult . fromJSON)
  pure $ (key, bal, guard)
txLogToAccountInfo _ = Nothing

rosettaTransaction :: CommandResult Hash -> [Operation] -> Transaction
rosettaTransaction cr ops =
  Transaction
    { _transaction_transactionId = TransactionId $ requestKeyToB16Text (_crReqKey cr)
    , _transaction_operations = ops
    , _transaction_metadata = txMeta
    }
  where
    -- Include information on related transactions (i.e. continuations)
    txMeta = case _crContinuation cr of
      Nothing -> Nothing
      Just pe -> Just $ HM.fromList [("related-transaction", toJSON pe)]   -- TODO: document, nicer?

indexedOperations :: [UnindexedOperation] -> [Operation]
indexedOperations logs = zipWith (\f i -> f i) logs [(0 :: Word64)..]

operation
    :: RosettaOperationStatus
    -> OperationType
    -> TxId
    -> AccountLog
    -> Word64
    -> Operation
operation ostatus otype txid (key, bal, guard) idx =
  Operation
    { _operation_operationId = OperationId idx Nothing
    , _operation_relatedOperations = Nothing -- TODO: implement
    , _operation_type = sshow otype
    , _operation_status = sshow ostatus
    , _operation_account = Just accountId
    , _operation_amount = Just $ kdaToRosettaAmount bal
    , _operation_metadata = Just $ HM.fromList [("txId", toJSON txid)] -- TODO: document
    }
  where
    accountId = AccountId
      { _accountId_address = key
      , _accountId_subAccount = Nothing  -- assumes coin acct contract only
      , _accountId_metadata = Just accountIdMeta
      }
    accountIdMeta = HM.fromList [("ownership", guard)]  -- TODO: document


-- Timestamp of the block in milliseconds since the Unix Epoch.
-- NOTE: Chainweb provides this timestamp in microseconds.
rosettaTimestamp :: BlockHeader -> Word64
rosettaTimestamp bh = BA.unLE . BA.toLE $ fromInteger msTime
  where
    msTime = int $ microTime `div` ms
    TimeSpan ms = millisecond
    microTime = encodeTimeToWord64 $ _bct (_blockCreationTime bh)


hushResult :: Result a -> Maybe a
hushResult (Success w) = Just w
hushResult (Error _) = Nothing
