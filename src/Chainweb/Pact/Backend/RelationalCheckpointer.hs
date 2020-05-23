{-# LANGUAGE TupleSections #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module: Chainweb.Pact.Backend.RelationalCheckpointer
-- Copyright: Copyright © 2018 - 2020 Kadena LLC.
-- License: See LICENSE file
-- Maintainers: Emmanuel Denloye <emmanuel@kadena.io>
-- Stability: experimental
--
-- Pact Checkpointer for Chainweb
module Chainweb.Pact.Backend.RelationalCheckpointer
  ( initRelationalCheckpointer
  , initRelationalCheckpointer'
  ) where

import Control.Concurrent.MVar
import Control.Lens
import Control.Monad
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.State (gets)

import Data.ByteString (ByteString)
import Data.Aeson hiding (encode,(.=))
import qualified Data.DList as DL
import Data.Foldable (toList,foldl')
import Data.Int
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HashMap
import qualified Data.List as List
import Data.Serialize hiding (get)
import qualified Data.Text as T
import Data.Tuple.Strict
import qualified Data.Vector as V
import qualified Data.Vector.Algorithms.Tim as TimSort

import Database.SQLite3.Direct

import Prelude hiding (log)

-- pact

import Pact.Interpreter (PactDbEnv(..))
import Pact.Types.Hash (PactHash, TypedHash(..))
import Pact.Types.Logger (Logger(..))
import Pact.Types.Persistence
import Pact.Types.SQLite

-- chainweb
import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeight
import Chainweb.Pact.Backend.ChainwebPactDb
import Chainweb.Pact.Backend.Types
import Chainweb.Pact.Backend.Utils
import Chainweb.Pact.Service.Types
import Chainweb.Utils
import Chainweb.Version


initRelationalCheckpointer
    :: BlockState
    -> SQLiteEnv
    -> Logger
    -> ChainwebVersion
    -> IO CheckpointEnv
initRelationalCheckpointer bstate sqlenv loggr v =
    snd <$!> initRelationalCheckpointer' bstate sqlenv loggr v

-- for testing
initRelationalCheckpointer'
    :: BlockState
    -> SQLiteEnv
    -> Logger
    -> ChainwebVersion
    -> IO (PactDbEnv', CheckpointEnv)
initRelationalCheckpointer' bstate sqlenv loggr v = do
    let dbenv = BlockDbEnv sqlenv loggr
    db <- newMVar (BlockEnv dbenv bstate)
    runBlockEnv db $ initSchema
    return
      (PactDbEnv' (PactDbEnv chainwebPactDb db),
       CheckpointEnv
        { _cpeCheckpointer =
            Checkpointer
            {
                _cpRestore = doRestore v db
              , _cpSave = doSave db
              , _cpDiscard = doDiscard db
              , _cpGetLatestBlock = doGetLatest db
              , _cpBeginCheckpointerBatch = doBeginBatch db
              , _cpCommitCheckpointerBatch = doCommitBatch db
              , _cpDiscardCheckpointerBatch = doDiscardBatch db
              , _cpLookupBlockInCheckpointer = doLookupBlock db
              , _cpGetBlockParent = doGetBlockParent db
              , _cpRegisterProcessedTx = doRegisterSuccessful db
              , _cpLookupProcessedTx = doLookupSuccessful db
              , _cpGetBlockHistory = doGetBlockHistory db
              }
        , _cpeLogger = loggr
        })

type Db = MVar (BlockEnv SQLiteEnv)


doRestore :: ChainwebVersion -> Db -> Maybe (BlockHeight, ParentHash) -> IO PactDbEnv'
doRestore v dbenv (Just (bh, hash)) = runBlockEnv dbenv $ do
    setModuleNameFix
    clearPendingTxState
    void $ withSavepoint PreBlock $ handlePossibleRewind bh hash
    beginSavepoint Block
    return $! PactDbEnv' $! PactDbEnv chainwebPactDb dbenv
  where
    -- Module name fix follows the restore call to checkpointer.
    setModuleNameFix = bsModuleNameFix .= enableModuleNameFix v bh
doRestore _ dbenv Nothing = runBlockEnv dbenv $ do
    clearPendingTxState
    withSavepoint DbTransaction $
      callDb "doRestoreInitial: resetting tables" $ \db -> do
        exec_ db "DELETE FROM BlockHistory;"
        exec_ db "DELETE FROM [SYS:KeySets];"
        exec_ db "DELETE FROM [SYS:Modules];"
        exec_ db "DELETE FROM [SYS:Namespaces];"
        exec_ db "DELETE FROM [SYS:Pacts];"
        tblNames <- qry_ db "SELECT tablename FROM VersionedTableCreation;" [RText]
        forM_ tblNames $ \tbl -> case tbl of
            [SText t] -> exec_ db ("DROP TABLE [" <> t <> "];")
            _ -> internalError "Something went wrong when resetting tables."
        exec_ db "DELETE FROM VersionedTableCreation;"
        exec_ db "DELETE FROM VersionedTableMutation;"
        exec_ db "DELETE FROM TransactionIndex;"
    beginSavepoint Block
    assign bsTxId 0
    return $! PactDbEnv' $ PactDbEnv chainwebPactDb dbenv

doSave :: Db -> BlockHash -> IO ()
doSave dbenv hash = runBlockEnv dbenv $ do
    height <- gets _bsBlockHeight
    runPending height
    nextTxId <- gets _bsTxId
    blockHistoryInsert height hash nextTxId
    commitSavepoint Block
    clearPendingTxState
  where
    runPending :: BlockHeight -> BlockHandler SQLiteEnv ()
    runPending bh = do
        newTables <- use $ bsPendingBlock . pendingTableCreation
        writes <- use $ bsPendingBlock . pendingWrites
        createNewTables bh $ toList newTables
        writeV <- toVectorChunks writes
        callDb "save" $ backendWriteUpdateBatch bh writeV
        indexPendingPactTransactions

    prepChunk [] = error "impossible: empty chunk from groupBy"
    prepChunk chunk@(h:_) = (Utf8 $ _deltaTableName h, V.fromList chunk)

    toVectorChunks writes = liftIO $ do
        mv <- V.unsafeThaw . V.fromList . DL.toList . DL.concat $
              HashMap.elems writes
        TimSort.sort mv
        l' <- V.toList <$> V.unsafeFreeze mv
        let ll = List.groupBy (\a b -> _deltaTableName a == _deltaTableName b) l'
        return $ map prepChunk ll

    createNewTables
        :: BlockHeight
        -> [ByteString]
        -> BlockHandler SQLiteEnv ()
    createNewTables bh = mapM_ (\tn -> createUserTable (Utf8 tn) bh)

-- | Discards all transactions since the most recent @Block@ savepoint and
-- removes the savepoint from the transaction stack.
--
doDiscard :: Db -> IO ()
doDiscard dbenv = runBlockEnv dbenv $ do
    clearPendingTxState
    rollbackSavepoint Block

    -- @ROLLBACK TO n@ only rolls back updates up to @n@ but doesn't remove the
    -- savepoint. In order to also pop the savepoint from the stack we commit it
    -- (as empty transaction). <https://www.sqlite.org/lang_savepoint.html>
    --
    commitSavepoint Block

doGetLatest :: Db -> IO (Maybe (BlockHeight, BlockHash))
doGetLatest dbenv =
    runBlockEnv dbenv $ callDb "getLatestBlock" $ \db -> do
        r <- qry_ db qtext [RInt, RBlob] >>= mapM go
        case r of
          [] -> return Nothing
          (!o:_) -> return (Just o)
  where
    qtext = "SELECT blockheight, hash FROM BlockHistory \
            \ ORDER BY blockheight DESC LIMIT 1"

    go [SInt hgt, SBlob blob] =
        let hash = either error id $ Data.Serialize.decode blob
        in return (fromIntegral hgt, hash)
    go _ = fail "impossible"

doBeginBatch :: Db -> IO ()
doBeginBatch db = runBlockEnv db $ beginSavepoint BatchSavepoint

doCommitBatch :: Db -> IO ()
doCommitBatch db = runBlockEnv db $ commitSavepoint BatchSavepoint

-- | Discards all transactions since the most recent @BatchSavepoint@ savepoint
-- and removes the savepoint from the transaction stack.
--
doDiscardBatch :: Db -> IO ()
doDiscardBatch db = runBlockEnv db $ do
    rollbackSavepoint BatchSavepoint

    -- @ROLLBACK TO n@ only rolls back updates up to @n@ but doesn't remove the
    -- savepoint. In order to also pop the savepoint from the stack we commit it
    -- (as empty transaction). <https://www.sqlite.org/lang_savepoint.html>
    --
    commitSavepoint BatchSavepoint

doLookupBlock :: Db -> (BlockHeight, BlockHash) -> IO Bool
doLookupBlock dbenv (bheight, bhash) = runBlockEnv dbenv $ do
    r <- callDb "lookupBlock" $ \db ->
         qry db qtext [SInt $ fromIntegral bheight, SBlob (encode bhash)]
                      [RInt]
    liftIO (expectSingle "row" r) >>= \case
        [SInt n] -> return $! n /= 0
        _ -> internalError "doLookupBlock: output mismatch"
  where
    qtext = "SELECT COUNT(*) FROM BlockHistory WHERE blockheight = ? \
            \ AND hash = ?;"

doGetBlockParent :: Db -> (BlockHeight, BlockHash) -> IO (Maybe BlockHash)
doGetBlockParent dbenv (bh, hash) = do
    blockFound <- doLookupBlock dbenv (bh, hash)
    if not blockFound
      then return Nothing
      else runBlockEnv dbenv $ do
        r <- callDb "getBlockParent" $ \db -> qry db qtext [SInt (fromIntegral (pred bh))] [RBlob]
        case r of
           [[SBlob blob]] -> either (internalError . T.pack) (return . return) $! Data.Serialize.decode blob
           _ -> internalError "doGetBlockParent: output mismatch"
  where
    qtext = "SELECT hash FROM BlockHistory WHERE blockheight = ?"


doRegisterSuccessful :: Db -> PactHash -> IO ()
doRegisterSuccessful dbenv (TypedHash hash) =
    runBlockEnv dbenv (indexPactTransaction hash)


doLookupSuccessful :: Db -> PactHash -> IO (Maybe (T2 BlockHeight BlockHash))
doLookupSuccessful dbenv (TypedHash hash) = runBlockEnv dbenv $ do
    r <- callDb "doLookupSuccessful" $ \db ->
         qry db qtext [ SBlob hash ] [RInt, RBlob] >>= mapM go
    case r of
        [] -> return Nothing
        (!o:_) -> return (Just o)
  where
    qtext = "SELECT blockheight, hash FROM \
            \TransactionIndex INNER JOIN BlockHistory \
            \USING (blockheight) WHERE txhash = ?;"
    go [SInt h, SBlob blob] = do
        !hsh <- either fail return $ Data.Serialize.decode blob
        return $! T2 (fromIntegral h) hsh
    go _ = fail "impossible"

doGetBlockHistory :: FromJSON v => Db -> BlockHeader -> Domain k v -> IO BlockTxHistory
doGetBlockHistory dbenv blockHeader d = runBlockEnv dbenv $ do
  callDb "doGetBlockHistory" $ \db -> do
    endTxId <- getEndTxId db bHeight (_blockHash blockHeader)
    startTxId <- getEndTxId db (pred bHeight) (_blockParent blockHeader)
    history <- queryHistory db (domainTableName d) startTxId endTxId
    return $! BlockTxHistory $ foldl' groupByTxid mempty history
  where

    bHeight = _blockHeight blockHeader

    groupByTxid :: Ord a => M.Map a [b] -> (a,b) -> M.Map a [b]
    groupByTxid r (t,l) = M.insertWith (++) t [l] r

    getEndTxId db bhi bha = do
      r <- qry db
        "SELECT endingtxid FROM BlockHistory WHERE blockheight = ? and hash = ?;"
        [SInt $ fromIntegral $ bhi, SBlob $ encode $ bha]
        [RInt]
      case r of
        [[SInt tid]] -> return tid
        [] -> throwM $ BlockHeaderLookupFailure $ "doGetBlockHistory: not in db: " <>
              sshow (bhi,bha)
        _ -> internalError $ "doGetBlockHistory: expected single-row int result, got " <> sshow r

    queryHistory :: Database -> Utf8 -> Int64 -> Int64 -> IO [(TxId,TxLog Value)]
    queryHistory db tableName s e = do
      let sql = "SELECT txid, rowkey, rowdata FROM [" <> tableName <>
                "] WHERE txid > ? AND txid <= ?"
      r <- qry db sql
           [SInt s,SInt e]
           [RInt,RText,RBlob]
      forM r $ \case
        [SInt txid, SText key, SBlob value] -> (fromIntegral txid,) <$> toTxLog d key value
        err -> internalError $
               "readHistoryResult': Expected single row with three columns as the \
               \result, got: " <> T.pack (show err)
