module Kaos.Targ (targExpand, stripTarg) where

--import Control.Monad (guard)
import Control.Monad.Cont

import Data.Generics
import qualified Data.Map as M
import Data.Maybe

import Kaos.AST
import Kaos.Core
import Kaos.Slot
import Kaos.KaosM
import Kaos.CoreAccess
import Kaos.CoreAlias

import qualified Kaos.AliasMap as AM

debugDumpCore :: Show t => String -> Core t -> KaosM (Core t)
debugDumpCore tag core = do
    debugDump tag (dumpCore $ fmap (const ()) core)
    debugDump (tag ++ "-raw") (dumpCore core)
    return core

targExpand :: Core t -> KaosM (Core ())
targExpand d = return (fmap (const ()) d)
           >>= tagTempSlots
           >>= debugDumpCore "dump-targ-marked"
           >>= markAccess
           >>= expandBackward
           >>= debugDumpCore "dump-targ-expanded"
           >>= injectAssignments
           >>= markAccess -- may be out of date
           >>= markAliasing
           >>= mergeAdjacent
           >>= debugDumpCore "dump-targ-merged"
           >>= (return . (fmap (const ())))
           >>= expandForward
           >>= debugDumpCore "dump-targ-final"

tagTempSlots :: Core () -> KaosM (Core ())
tagTempSlots = everywhereM (mkM tagLine)
    where
        tagLine :: CoreLine () -> KaosM (CoreLine ())
        tagLine (CoreTargReader _ s b) = do
            ts <- newSlot typeObj
            return $ CoreTargReader ts s b
        tagLine l = return l

usesTarg :: CoreLine t -> Bool
usesTarg core = worker `runCont` id
    where
        worker = callCC $ \ret -> do
            everywhereM (mkM (checkTarg ret)) $ fmap (const ()) core
            return False
        checkTarg :: (Bool -> Cont Bool (CoreLine ()))
                  -> CoreLine ()
                  -> Cont Bool (CoreLine ())
        checkTarg ret (CoreTargReader _ _ _) = ret True
        checkTarg ret (CoreTargWriter _ _) = ret True
        checkTarg _ t = return t

injectAssignments :: Core AccessMap -> KaosM (Core AccessMap)
injectAssignments = return . everywhere (mkT injectOne)
    where
        injectOne :: CoreLine AccessMap -> CoreLine AccessMap
        injectOne (CoreTargWriter slot (CB ls)) =
            CoreTargWriter slot (CB $ ls ++ [(targAssign slot, undefined)])
        injectOne l = l

expandForward  :: Core () -> KaosM (Core ())
expandForward = return . everywhere' (mkT expandOne)
    where
        expandOne :: [(CoreLine (), ())]
                  -> [(CoreLine (), ())]
        -- by now, reads and writes have been merged,
        -- and crucially each write has its assignment statement added
        -- we can now expand forward to swallow up targ-neutral lines
        expandOne p@(_:(line, ()):_)
            | usesTarg line
            = p
        expandOne ((CoreTargReader ts s (CB blk), ()):lp:ls)
            = expandOne $ (CoreTargReader ts s (CB (blk ++ [lp])), ()):ls
        expandOne ((CoreTargWriter s (CB blk), ()):lp:ls)
            = expandOne $ (CoreTargWriter s (CB (blk ++ [lp])), ()):ls
        expandOne p = p

expandBackward :: Core AccessMap -> KaosM (Core AccessMap)
expandBackward = return . everywhere (mkT expandOne)
    where
        expandOne :: [(CoreLine AccessMap, AccessMap)]
                  -> [(CoreLine AccessMap, AccessMap)]
        -- When an assignment appears before a targread, follow the rename
        expandOne (a@(CoreAssign vdest vsrc, am1):(CoreTargReader ts s (CB blk), am2):remain)
            | vdest == s || vsrc == s
            = (CoreTargReader ts vsrc (CB $ a:blk), mergedAM):remain
            where
                mergedAM = am1 `mergeAM` am2       
        -- Do not expand across other targ blocks; this is a job for later phases
        expandOne xs@((prev, _):_)
            | usesTarg prev
            = xs
        -- Read swallows anything that doesn't write to its variable
        expandOne (target@(_, targetAM):(CoreTargReader ts s (CB blk), am2):xs)
            | not (targetAM `writesSlot` ts || targetAM `writesSlot` s)
            = (CoreTargReader ts s (CB $ target:blk), am2 `mergeAM` targetAM):xs
        -- Write swallows anything at all
        expandOne (target@(_, targetAM):(CoreTargWriter s (CB blk), am2):xs)
            = (CoreTargWriter s (CB $ target:blk), am2 `mergeAM` targetAM):xs
        -- Leave anything else alone
        expandOne xs = xs

writesSlot :: AccessMap -> Slot -> Bool
(AM am) `writesSlot` slot = (fromMaybe NoAccess $ M.lookup slot am) > ReadAccess

mergeAdjacent :: Core AliasTag -> KaosM (Core AliasTag)
mergeAdjacent = return . everywhere (mkT mergeBlock)
    where
        mergeBlock :: CoreBlock AliasTag -> CoreBlock AliasTag
        mergeBlock (CB ls) = CB $ slidingMerge ls
            where
                slidingMerge (a@(lineA, aliasA):b@(lineB, aliasB):r)
                    = case tryMerge lineA lineB aliasA aliasB of
                        Just c  -> slidingMerge (c:r)
                        Nothing -> a:(slidingMerge (b:r))
                slidingMerge l = l

                tryMerge (CoreTargReader ts1 s1 (CB blk1)) (CoreTargReader ts2 _ (CB blk2)) _ rAlias
                    | AM.aliases ts1 ts2 rAlias
                    = Just $ (CoreTargReader ts1 s1 (CB (blk1 ++ blk2)), rAlias)
                tryMerge (CoreTargWriter s1 (CB blk1)) (CoreTargReader _ s2 (CB blk2)) wAlias rAlias
                    | AM.aliases s1 s2 wAlias
                    = Just $ (CoreTargWriter s1 (CB $ blk1 ++ blk2), rAlias)
                tryMerge _ _ _ _ = Nothing

stripTarg :: Core () -> KaosM (Core ())
stripTarg = return . everywhere (mkT stripOneTarg)
    where
        stripOneTarg :: [(CoreLine (), ())] -> [(CoreLine (), ())]
        stripOneTarg = map (\l -> (l, ())) . stripOneTarg' . map fst
        stripOneTarg' :: [CoreLine ()] -> [CoreLine ()]
        stripOneTarg' ((CoreTargReader tempslot slot block):remain) =
               [(CoreAssign tempslot slot),(CoreLine [TokenLiteral "targ", TokenSlot (SA tempslot ReadAccess)])]
            ++ (map fst . unCB $ block)
            ++ remain
        stripOneTarg' ((CoreTargWriter _ block):remain) =
               (map fst . unCB $ block)
            ++ remain
        stripOneTarg' l = l

targAssign :: Slot -> CoreLine a
targAssign slot = CoreLine [TokenLiteral "seta", TokenSlot (SA slot WriteAccess), TokenLiteral "targ"]
