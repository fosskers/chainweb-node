{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- |
-- Module: Chainweb.WebBlockHeaderDB
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.WebBlockHeaderDB
( WebBlockHeaderDb
, mkWebBlockHeaderDb
, initWebBlockHeaderDb
, getWebBlockHeaderDb
, webBlockHeaderDb
, lookupWebBlockHeaderDb
, insertWebBlockHeaderDb
, blockAdjacentParentHeaders
, checkBlockHeaderGraph
, checkBlockAdjacentParents
) where

import Control.Lens
import Control.Monad
import Control.Monad.Catch

import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import Data.Reflection

-- internal modules

import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.ChainId
import Chainweb.Graph
import Chainweb.TreeDB
import Chainweb.Utils
import Chainweb.Version

-- -------------------------------------------------------------------------- --
-- Web Chain Database

-- | Every WebChain has the following properties
--
-- * All entires of _webBlockHeaderDb are valid BlockHeaderDbs
-- * There are no dangling adjacent parent hashes
-- * The adjacent hashes of all block headers conform with the chain graph
--   of the web chain.
--
--  TODO: in order to enforce these invariants the insertion to
--  the dbs must be guarded see issue #123.
--
data WebBlockHeaderDb = WebBlockHeaderDb
    { _webBlockHeaderDb :: !(HM.HashMap ChainId BlockHeaderDb)
    , _webChainGraph :: !ChainGraph
    }

webBlockHeaderDb :: Getter WebBlockHeaderDb (HM.HashMap ChainId BlockHeaderDb)
webBlockHeaderDb = to _webBlockHeaderDb

type instance Index WebBlockHeaderDb = ChainId
type instance IxValue WebBlockHeaderDb = BlockHeaderDb

instance IxedGet WebBlockHeaderDb where
    ixg i = webBlockHeaderDb . ix i
    {-# INLINE ixg #-}

instance HasChainGraph WebBlockHeaderDb where
    _chainGraph = _webChainGraph
    {-# INLINE _chainGraph #-}

initWebBlockHeaderDb
    :: Given ChainGraph
    => ChainwebVersion
    -> IO WebBlockHeaderDb
initWebBlockHeaderDb v = WebBlockHeaderDb
    <$> itraverse (\cid _ -> initBlockHeaderDb (conf cid)) (HS.toMap chainIds)
    <*> pure given
  where
    conf cid = Configuration (genesisBlockHeader v given cid)

mkWebBlockHeaderDb
    :: ChainGraph
    -> HM.HashMap ChainId BlockHeaderDb
    -> WebBlockHeaderDb
mkWebBlockHeaderDb graph m = WebBlockHeaderDb m graph

getWebBlockHeaderDb
    :: MonadThrow m
    => HasChainId p
    => Given WebBlockHeaderDb
    => p
    -> m BlockHeaderDb
getWebBlockHeaderDb p = do
    give (_chainGraph (given @WebBlockHeaderDb)) $ checkWebChainId p
    return $ _webBlockHeaderDb given HM.! _chainId p

lookupWebBlockHeaderDb
    :: Given WebBlockHeaderDb
    => BlockHash
    -> IO BlockHeader
lookupWebBlockHeaderDb h = do
    give (_chainGraph (given @WebBlockHeaderDb)) $ checkWebChainId h
    db <- getWebBlockHeaderDb h
    lookupM db h

blockAdjacentParentHeaders
    :: Given WebBlockHeaderDb
    => BlockHeader
    -> IO (HM.HashMap ChainId BlockHeader)
blockAdjacentParentHeaders = traverse lookupWebBlockHeaderDb
    . _getBlockHashRecord
    . _blockAdjacentHashes

insertWebBlockHeaderDb
    :: Given WebBlockHeaderDb
    => BlockHeader
    -> IO ()
insertWebBlockHeaderDb h = do
    db <- getWebBlockHeaderDb h
    checkBlockAdjacentParents h
    insert db h

-- -------------------------------------------------------------------------- --
-- Checks and Properties

-- | Given a 'ChainGraph' @g@, @checkBlockHeaderGraph h@ checks that the
-- @_chainId h@ is a vertex in @g@ and that the adjacent hashes of @h@
-- correspond exactly to the adjacent vertices of @h@ in @g@.
--
-- TODO: move this to "Chainweb.BlockHeader"?
--
checkBlockHeaderGraph
    :: MonadThrow m
    => Given ChainGraph
    => BlockHeader
    -> m ()
checkBlockHeaderGraph b = void
    $ checkAdjacentChainIds b $ Expected $ _blockAdjacentChainIds b

-- | Given a 'WebBlockHeaderDb' @db@, @checkBlockAdjacentParents h@ checks that
-- all referenced adjacent parents block headers exist in @db@.
--
checkBlockAdjacentParents
    :: Given WebBlockHeaderDb
    => BlockHeader
    -> IO ()
checkBlockAdjacentParents = void . blockAdjacentParentHeaders
