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

module Kaos.Rename (renameLexicals) where

import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Cont
import qualified Data.Map as M
import Data.Maybe

import Kaos.AST
import Kaos.Slot
import Kaos.Toplevel

import Kaos.KaosM

data ReaderContext = RC { rcMacros :: MacroContext
                        , rcLevel  :: Int
                        }

enterMacro :: MacroContext -> RenameT a -> RenameT a
enterMacro mc = local (\s -> s { rcMacros = mc, rcLevel = succ $ rcLevel s })

getMacro :: String -> Int -> RenameT Macro
getMacro name argc = do
    macro <- tryGetMacro name argc
    case macro of
        Just m -> return m
        Nothing -> do
            ctx <- asks rcMacros
            let macroGroup = fromMaybe M.empty (M.lookup name ctx)
            when (M.null macroGroup) $
                compileError $ "Unknown macro or builtin " ++ (show name)
            let cand = map (\(_, m) -> "\t" ++ macroPrototype m) (M.toList macroGroup)
            compileError $ unlines (("No matching macro for call to " ++ (show name) ++ "; candidates are:"):cand)

tryGetMacro :: String -> Int -> RenameT (Maybe Macro)
tryGetMacro name argc = do
    ctx <- asks rcMacros
    return (M.lookup name ctx >>= M.lookup argc)

type RenameT = StateT (M.Map String Slot) (ReaderT ReaderContext KaosM)

enterBlock :: RenameT a -> RenameT a
enterBlock m = do
    s <- get
    r <- m
    put s
    return r

renameLexicals :: MacroContext -> Statement String -> KaosM (Statement Slot)
renameLexicals ctx st =
    runReaderT (evalStateT (renameStatement st) M.empty) (RC ctx 0)

renameStatement :: Statement String -> RenameT (Statement Slot)
renameStatement (SContext c s) = 
    context c $ liftM (SContext c) (renameStatement s)
renameStatement (SFlush l) =
    return $ SFlush l -- this probably shouldn't actually appear
renameStatement (SDeclare t decls) = fmap (SBlock . concat) $ mapM declOne decls
    where
        declOne (name, ive) = do
            registerVar t name
            case ive of
                Nothing -> return []
                Just e -> do
                    let assignment = SExpr (EAssign (ELexical name) e)
                    rv <- renameStatement assignment
                    return [rv]
renameStatement (SBlock ls) = fmap SBlock $ enterBlock (fmap concat $ mapM renameLine ls)
    where
        renameLine l = do
            l' <- checkpoint (SBlock []) $ renameStatement l
            lev <- asks rcLevel
            return [l', SFlush $ succ lev]
renameStatement (SExpr e)       = fmap SExpr  $ renameExpr e
renameStatement (SCond c s1 s2) =
    liftM3 SCond (renameCond c) (renameStatement s1) (renameStatement s2)
renameStatement (SDoUntil c s) =
    liftM2 SDoUntil (renameCond c) (renameStatement s)
renameStatement (SUntil c s) =
    liftM2 SUntil (renameCond c) (renameStatement s)
renameStatement (SICaos l) = fmap SICaos $ mapM renameILine l
renameStatement (SInstBlock s) = liftM SInstBlock $ renameStatement s
renameStatement (SIterCall name args argNames block) = do
    m <- getMacro ("iter:" ++ name) (length args)
    when ( (length argNames) /= (length $ miArgTypes $ mbType m)) $
        compileError "Iteree block has the wrong number of arguments"
    lexCtx <- get
    macroCtx <- asks rcMacros
    let innerArgs = zipWith (\argN typ -> MacroArg argN typ)
                            argNames
                            (miArgTypes $ mbType m)
    let ymacro = defaultMacro   { mbName = "_yield"
                                , mbType = MacroLValue
                                , mbArgs = innerArgs
                                , mbCode = block
                                , mbRetType = typeVoid
                                , mbLexVars = lexCtx
                                , mbContext = macroCtx
                                }
    newCtx <- addMacroToCtx True ymacro (mbContext m)
    let mmacro = m  { mbContext = newCtx }
    fmap SExpr $ renameMacro mmacro args
renameStatement (SScriptHead ex) = fmap SScriptHead $ mapM renameExpr ex

renameILine :: InlineCAOSLine String -> RenameT (InlineCAOSLine Slot)
renameILine (ICAssign v1 v2) = liftM2 ICAssign (lex2slot v1) (lex2slot v2)
renameILine (ICConst v1 cv) = do
    s <- lex2slot v1
    return $ ICConst s cv
renameILine (ICLine tl) = liftM ICLine $ mapM renameIToken tl
renameILine (ICTargReader vs body) =
    liftM2 ICTargReader (lex2slot vs) (mapM renameILine body)
renameILine (ICTargWriter vs body) =
    liftM2 ICTargWriter (lex2slot vs) (mapM renameILine body)
renameILine (ICLoop body) = liftM ICLoop (mapM renameILine body)
renameILine (ICKaos body) = liftM ICKaos (renameStatement body)
renameILine (ICLValue maxLevel l tokens) = do
    slot    <- lex2slot l
    tokens' <- mapM renameIToken tokens
    level   <- asks (min maxLevel . rcLevel)
    return $ ICLValue level slot tokens'
renameILine ICTargZap = return ICTargZap

renameIToken :: InlineCAOSToken String -> RenameT (InlineCAOSToken Slot)
renameIToken (ICVar l at) = do
    s <- lex2slot l
    return $ ICVar s at
renameIToken (ICWord w) = return $ ICWord w

renameExpr :: (Expression String) -> RenameT (Expression Slot)
renameExpr (EConst c) = return $ EConst c
renameExpr (EBinaryOp s e1 e2) =
    liftM2 (EBinaryOp s) (renameExpr e1) (renameExpr e2)
renameExpr (EAssign (ELexical l) e2) =
    lexSwitch l "set:" (\s -> liftM (EAssign $ ELexical s) (renameExpr e2))
                       (\c -> renameExpr (EAssign c e2))
renameExpr (EAssign (ECall name e) e2) =
    renameExpr (ECall ("set:" ++ name) (e2:e))
renameExpr (EAssign e _) = compileError $ "Not an LValue: " ++ (show e)
renameExpr (ELexical l) =
    lexSwitch l "" (return . ELexical) renameExpr


renameExpr (EBoolCast e) = liftM EBoolCast $ renameCond e

--renameExpr (ECall s e) = fmap (ECall s) $ mapM renameExpr e
renameExpr (ECall name e) = do
    macroM <- getMacro name (length e)
    renameMacro macroM e
renameExpr (EBuiltin b ex) = fmap (EBuiltin b) (mapM renameExpr ex)
renameExpr (EStmt result code) = liftM2 EStmt (liftMaybe lex2slot result) (renameStatement code)

lexSwitch :: String
          -> String
          -> (Slot -> RenameT a)
          -> (Expression String -> RenameT a)
          -> RenameT a
lexSwitch l prefix ifLex ifMacro = do
    r <- lex2slot' l
    case r of
        Just s -> ifLex s
        Nothing -> do
            m <- tryGetMacro (prefix ++ l) 0
            case m of 
                Just (Macro{}) -> ifMacro (ECall l [])
                _ -> notInScope l

renameMacro :: Macro -> [Expression String] -> RenameT (Expression Slot)
renameMacro macro e = do
    instd <- mapM (uncurry instExpr) (zip e $ map maType (mbArgs macro))
    let expSlots = map fst instd
    let oprefix  = map snd instd
    (iprefix, newMap) <- instantiateVars [] M.empty (mbArgs macro) expSlots
    oldMap <- get
    put $ newMap
    registerVar (mbRetType macro) "return"
    inner <- enterMacro (mbContext macro) $ renameStatement $ (SBlock $ iprefix ++ [mbCode macro])
    newMap' <- get
    put oldMap
    return $ EStmt (M.lookup "return" newMap') (SBlock (oprefix ++ [inner]))
    where
        name = mbName macro
        instExpr    :: Expression String
                    -> CAOSType
                    -> RenameT (Slot, Statement Slot)
        instExpr expr t = do
            slot <- newSlot t
            rexpr <- renameExpr expr
            return (slot, SExpr $ EAssign (ELexical slot) rexpr)
        instantiateVars prefix argMap [] [] = return (prefix, argMap)
        instantiateVars _ _ [] (_:_) = compileError $ "Too many args for macro '" ++ name ++ "'"
        instantiateVars _ _ (_:_) []
            = internalError $ "Too few args for macro '" ++ name ++ "'"
        instantiateVars prefix argMap (harg:args) (hexp:exps) = do
            instantiateVars prefix (M.insert (maName harg) hexp argMap) args exps



liftMaybe :: Monad m => (a -> m b) -> Maybe a -> m (Maybe b)
liftMaybe _ Nothing  = return Nothing
liftMaybe f (Just v) = liftM Just $ f v 

lex2slot' :: String -> RenameT (Maybe Slot)
lex2slot' l = do
    s <- get
    return $ M.lookup l s

lex2slot :: String -> RenameT Slot
lex2slot l = do
    r <- lex2slot' l
    case r of
        Just v -> return v
        Nothing -> notInScope l

notInScope :: String -> RenameT a
notInScope = compileError . ("Variable not in scope: " ++)

registerVar :: CAOSType -> String -> RenameT Slot
registerVar t name = do
    s <- get
    oldVar <- lex2slot' name
    oldMacro <- tryGetMacro name 0
    case (oldVar, oldMacro) of
        (Just _, _) -> warning $
            "Declaration of " ++ name ++ " shadows previously declared variable"
        (_, Just _) -> warning $
            "Declaration of " ++ name ++ " shadows previously declared macro"
        _ -> return ()
    slot <- lift $ newSlot t
    let slot' = slot { slotName = Just name }
    put $ M.insert name slot' s
    return slot

renameCond :: BoolExpr String -> RenameT (BoolExpr Slot)
renameCond (BAnd b1 b2) = liftM2 BAnd (renameCond b1) (renameCond b2)
renameCond (BOr b1 b2) = liftM2 BOr (renameCond b1) (renameCond b2)
renameCond (BCompare c e1 e2) =
    liftM2 (BCompare c) (renameExpr e1) (renameExpr e2)
renameCond e = fail $ "non-normal form in renameCond: " ++ show e
