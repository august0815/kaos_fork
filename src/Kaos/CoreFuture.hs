{-
   Kaos - A compiler for creatures scripts
   Copyright (C) 2005-2008  Bryan Donlan

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.
-}
module Kaos.CoreFuture (
    markFuture, markBlockFuture, markBlockFuture',
    Lookahead(..), Future,
    Futurable(..), lineFuture, FutureMap, FutureS
    ) where

import Kaos.Core
import Kaos.CoreTraverse
import Kaos.Slot
import Kaos.KaosM
import Data.List
import Data.Maybe
import Data.Generics
import Control.Monad.State hiding (State)
import Kaos.VirtRegister

import Control.Monad.Identity

import qualified Data.Map as M

data Lookahead = Bound VirtRegister
               | Read
               | Mutate
               deriving (Show, Eq, Ord, Data, Typeable)

type FutureMap = M.Map Slot Lookahead
data FutureS = FutureS { fsFuture ::  FutureMap
                       , fsAccess :: !AccessMap
                       } deriving (Eq, Ord, Show, Data, Typeable)
type Future  = Maybe Lookahead

class Futurable a where getFuture :: a -> FutureMap
instance Futurable FutureS where getFuture = fsFuture
instance LineAccess FutureS where getLineAccess = fsAccess

lineFuture :: Futurable t => (CoreLine t, t) -> FutureMap
lineFuture = getFuture . snd

type FutureM a = StateT FutureMap KaosM a

lookupFuture :: Slot -> FutureM Future
lookupFuture = gets . M.lookup

poisonFuture :: forall t. LineAccess t => Core t -> Core FutureS
poisonFuture = runIdentity . mapCoreM poison
    where
        poison :: CoreLine FutureS -> t -> Identity (CoreLine FutureS, FutureS)
        poison l la = return (l, FutureS err (getLineAccess la))
            where
                err = error $ "Using the future of a deep block: " ++
                                show (fmap (const ()) l)

markFuture :: LineAccess t => Core t -> KaosM (Core FutureS)
markFuture = markBlockFuture M.empty . poisonFuture

markBlockFuture ::
    FutureMap -> Core FutureS -> KaosM (Core FutureS)
markBlockFuture assumedFuture =
    fmap fst . markBlockFuture' assumedFuture

markBlockFuture' :: LineAccess t =>
    FutureMap -> Core t -> KaosM (Core FutureS, FutureMap)
markBlockFuture' assumedFuture = 
    flip runStateT assumedFuture . markBlock . poisonFuture

markBlock :: Core FutureS -> FutureM (Core FutureS)
markBlock (CB l) = do
    ls <- mapM markLine_ (reverse l)
    return $ CB (reverse ls)
    where
        markLine_ :: (CoreLine FutureS, FutureS) -> FutureM (CoreLine FutureS, FutureS)
        markLine_ (line, oldS) = do
            let acc = getLineAccess oldS
            future <- get
            line' <- markLine line acc
            return (line', FutureS future acc)

markLine :: CoreLine FutureS -> AccessMap -> FutureM (CoreLine FutureS)
markLine cl@(CoreNote _) _ = return cl
markLine cl@(CoreTouch sa) accM = do
    markLine (CoreLine [ TokenSlot sa ]) accM
    return cl
markLine cl@(CoreConst dest _) _ = do
    modify $ M.delete dest
    return cl

markLine cl@(CoreAssign dest src) _ = do
    fsrc  <- lookupFuture src
    fdest <- lookupFuture dest
    modify $ M.delete dest
    case (fsrc, fdest) of
        (Nothing, Nothing) -> return () -- discard
        (Just Read, Just Read) -> return () -- share
        (Nothing, _) -> do -- rename
            modify $ M.alter (const fdest) src
        (_, _) -> return () -- overwrite; we don't set future as it's already non-Nothing
    return cl

markLine (CoreTargReader tempslot readslot block) _ = do
    body <- markBlock block
    -- TARG temp
    markLine (CoreLine undefined) . AM $ M.singleton tempslot ReadAccess
    -- temp = slot
    markLine (CoreAssign tempslot readslot) undefined
    return $ CoreTargReader tempslot readslot body

markLine (CoreTargWriter slot block) _ = do
    -- temp = TARG
    markLine (CoreLine undefined) . AM $  M.singleton slot WriteAccess
    body <- markBlock block
    return $ CoreTargWriter slot body

markLine l acc = do
    mapM_ update (M.toList $ getAM acc)
    return l
    where
        update :: (Slot, AccessType) -> FutureM ()
        update (s, WriteAccess)  = modify $ M.delete s
        update (s, ReadAccess)   = modify $ flip M.alter s (`mplus` Just Read)
        update (s, MutateAccess) = modify . flip M.alter s $ \st ->
            case st of
                Just (Bound _) -> st
                _              -> Just Mutate
        update (_, NoAccess)     = return ()
