{-# LANGUAGE GADTs                      #-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TupleSections #-}
module Codegen.C.CompilerMonad where
import           AST.Simple
import           Control.Monad.Fail
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import qualified Data.BitVector                as Bv
import           Data.List                      ( intercalate
                                                , isInfixOf
                                                , findIndex
                                                )
import           Data.Functor.Identity
import           Data.Foldable
import qualified Data.Map                      as M
import           Data.Maybe                     ( catMaybes
                                                , fromMaybe
                                                , isJust
                                                , listToMaybe
                                                )
import           Data.Dynamic                   ( Dynamic
                                                , toDyn
                                                , fromDyn
                                                )
import qualified Util.ShowMap                  as SMap
import           Language.C.Syntax.AST          ( CFunDef )
import           Codegen.C.CUtils              as CUtils
import qualified IR.SMT.TySmt                  as Ty
import qualified Codegen.C.Memory              as Mem
import           Codegen.C.Memory               ( Mem )
import           Targets.SMT                    ( SMTResult )
import qualified IR.SMT.Assert                 as Assert
import           IR.SMT.Assert                  ( Assert )
import qualified Z3.Monad                      as Z

{-|

Module that defines the Compiler monad, the monad that keeps track of all internal
state for code generation. This state includes:
WHAT

There are many bits of low-hanging optimization fruit here. For example, we are doing
redundant state lookups, and storing lists of function names instead of a hash of
such a thing.

Structure: The compiler monad is defined in terms of three nested notions of state:
  * LexScope
  * FunctionScope
  * CompilerState
-}

type Version = Int

data SsaVar = SsaVar VarName Version
                deriving (Eq, Ord, Show)

-- TODO rename
data LexScope = LexScope { tys :: M.Map VarName Type
                         , vers :: M.Map VarName Version
                         , terms :: M.Map SsaVar CTerm
                         , lsPrefix :: String
                         } deriving (Show)
printLs :: LexScope -> IO ()
printLs s =
  putStr
    $  unlines
    $  ["   LexicalScope:", "    prefix: " ++ lsPrefix s, "    versions:"]
    ++ [ "     " ++ show var ++ ": " ++ show ver
       | (var, ver) <- M.toList (vers s)
       ]

-- Lexical scope functions

initialVersion :: Int
initialVersion = 0

lsWithPrefix :: String -> LexScope
lsWithPrefix s =
  LexScope { tys = M.empty, vers = M.empty, terms = M.empty, lsPrefix = s }

unknownVar :: VarName -> a
unknownVar var = error $ unwords ["Variable", var, "is unknown"]

lsDeclareVar :: VarName -> Type -> LexScope -> Mem LexScope
lsDeclareVar var ty scope = case M.lookup var (tys scope) of
  Nothing -> do
    -- First we add type and version entries for this variable
    let withTyAndVer = scope { vers = M.insert var initialVersion $ vers scope
                             , tys  = M.insert var ty $ tys scope
                             }
        ssaVar = lsGetSsaVar var withTyAndVer
    -- Now we declare it to the SMT layer
    term <- cppDeclVar ty (ssaVarAsString ssaVar)
    return $ withTyAndVer { terms = M.insert ssaVar term $ terms scope }
  Just actualTy ->
    error $ unwords ["Already declared", var, "to have type", show actualTy]


-- | Get the current version of the variable
lsGetVer :: VarName -> LexScope -> Version
lsGetVer var scope = fromMaybe (unknownVar var) (lsGetMaybeVer var scope)

lsGetMaybeVer :: VarName -> LexScope -> Maybe Version
lsGetMaybeVer var scope = M.lookup var (vers scope)

-- | Get current SsaVar
lsGetSsaVar :: VarName -> LexScope -> SsaVar
lsGetSsaVar var scope = SsaVar (lsScopedVar var scope) (lsGetVer var scope)

lsGetNextSsaVar :: VarName -> LexScope -> SsaVar
lsGetNextSsaVar var scope =
  SsaVar (lsScopedVar var scope) (lsGetVer var scope + 1)

lsScopedVar :: VarName -> LexScope -> String
lsScopedVar var scope = lsPrefix scope ++ "__" ++ var

-- | Get the C++ type of the variable
lsGetType :: VarName -> LexScope -> Type
lsGetType var scope = fromMaybe (unknownVar var) (M.lookup var (tys scope))

-- | Get a CTerm for the given var
lsGetTerm :: VarName -> LexScope -> CTerm
lsGetTerm var scope = fromMaybe
  (error $ unwords ["No term for", var])
  (M.lookup (lsGetSsaVar var scope) (terms scope))

lsSetTerm :: VarName -> CTerm -> LexScope -> LexScope
lsSetTerm var val scope =
  scope { terms = M.insert (lsGetSsaVar var scope) val $ terms scope }

lsNextVer :: VarName -> LexScope -> LexScope
lsNextVer var scope =
  scope { vers = M.insert var (lsGetVer var scope + 1) $ vers scope }

data FunctionScope = FunctionScope { -- Condition for current path
                                     conditionalGuards :: [Ty.TermBool]
                                     -- Conditions for each previous return
                                   , returnValueGuards :: [[Ty.TermBool]]
                                     -- Stack of lexical scopes. Innermost first.
                                   , lexicalScopes     :: [LexScope]
                                     -- number of next ls
                                   , lsCtr             :: Int
                                   , fsPrefix          :: String
                                   , retTerm           :: CTerm
                                   , retTermName       :: String
                                   }

listModify :: Functor m => Int -> (a -> m a) -> [a] -> m [a]
listModify 0 f (x : xs) = (: xs) `fmap` f x
listModify n f (x : xs) = (x :) `fmap` listModify (n - 1) f xs

fsFindLexScope :: VarName -> FunctionScope -> Int
fsFindLexScope var scope =
  fromMaybe (error $ unwords ["Cannot find", var, "in current scope"])
    $ fsFindLexScopeOpt var scope

fsFindLexScopeOpt :: VarName -> FunctionScope -> Maybe Int
fsFindLexScopeOpt var scope =
  findIndex (M.member var . tys) (lexicalScopes scope)

-- | Apply a modification function to the first scope containing the variable.
fsModifyLexScope
  :: Monad m
  => VarName
  -> (LexScope -> m LexScope)
  -> FunctionScope
  -> m FunctionScope
fsModifyLexScope var f scope = do
  n <- listModify (fsFindLexScope var scope) f $ lexicalScopes scope
  return $ scope { lexicalScopes = n }

-- | Apply a fetching function to the first scope containing the variable.
fsGetFromLexScope :: VarName -> (LexScope -> a) -> FunctionScope -> a
fsGetFromLexScope var f scope =
  let i  = fsFindLexScope var scope
      ls = lexicalScopes scope !! i
  in  f ls

fsDeclareVar :: VarName -> Type -> FunctionScope -> Mem FunctionScope
fsDeclareVar var ty scope = do
  head' <- lsDeclareVar var ty (head $ lexicalScopes scope)
  return $ scope { lexicalScopes = head' : tail (lexicalScopes scope) }

fsGetVer :: VarName -> FunctionScope -> Version
fsGetVer var = fsGetFromLexScope var (lsGetVer var)

fsGetType :: VarName -> FunctionScope -> Type
fsGetType var = fsGetFromLexScope var (lsGetType var)

fsGetSsaVar :: VarName -> FunctionScope -> SsaVar
fsGetSsaVar var = fsGetFromLexScope var (lsGetSsaVar var)

fsGetNextSsaVar :: VarName -> FunctionScope -> SsaVar
fsGetNextSsaVar var = fsGetFromLexScope var (lsGetNextSsaVar var)

fsGetTerm :: VarName -> FunctionScope -> CTerm
fsGetTerm var = fsGetFromLexScope var (lsGetTerm var)

fsSetTerm :: VarName -> CTerm -> FunctionScope -> FunctionScope
fsSetTerm var val =
  runIdentity . fsModifyLexScope var (Identity . lsSetTerm var val)

fsNextVer :: VarName -> FunctionScope -> FunctionScope
fsNextVer var = runIdentity . fsModifyLexScope var (Identity . lsNextVer var)

fsEnterLexScope :: FunctionScope -> FunctionScope
fsEnterLexScope scope =
  let newLs = lsWithPrefix (fsPrefix scope ++ "_lex" ++ show (lsCtr scope))
  in  scope { lsCtr         = 1 + lsCtr scope
            , lexicalScopes = newLs : lexicalScopes scope
            }

printFs :: FunctionScope -> IO ()
printFs s = do
  putStrLn " FunctionScope:"
  putStrLn $ "  Lex counter: " ++ show (lsCtr s)
  putStrLn "  LexicalScopes:"
  traverse_ printLs (lexicalScopes s)

fsExitLexScope :: FunctionScope -> FunctionScope
fsExitLexScope scope = scope { lexicalScopes = tail $ lexicalScopes scope }

fsPushGuard :: Ty.TermBool -> FunctionScope -> FunctionScope
fsPushGuard guard scope =
  scope { conditionalGuards = guard : conditionalGuards scope }

fsPopGuard :: FunctionScope -> FunctionScope
fsPopGuard scope = scope { conditionalGuards = tail $ conditionalGuards scope }

fsCurrentGuard :: FunctionScope -> Ty.TermBool
fsCurrentGuard = safeNary (Ty.BoolLit True) Ty.And . conditionalGuards

-- | Set the return value if we have not returned, and block future returns
fsReturn :: CTerm -> FunctionScope -> Compiler FunctionScope
fsReturn value scope =
  let
    returnCondition =
      Ty.BoolNaryExpr Ty.And [fsCurrentGuard scope, fsHasNotReturned scope]
    newScope = scope
      { returnValueGuards = conditionalGuards scope : returnValueGuards scope
      }
  in
    do
      a <- getAssignment
      let (retAssertion, retVal) = a (retTerm scope) value
      liftAssert $ Assert.implies returnCondition retAssertion
      whenM computingValues $ whenM (smtEvalBool returnCondition) $ setRetValue
        retVal
      return newScope

fsHasNotReturned :: FunctionScope -> Ty.TermBool
fsHasNotReturned =
  Ty.Not
    . safeNary (Ty.BoolLit False) Ty.Or
    . map (safeNary (Ty.BoolLit True) Ty.And)
    . returnValueGuards

fsWithPrefix :: String -> Type -> Mem FunctionScope
fsWithPrefix prefix ty = do
  let retTermName = ssaVarAsString $ SsaVar (prefix ++ "__return") 0
  retTerm <- cppDeclVar ty retTermName
  let fs = FunctionScope { conditionalGuards = []
                         , returnValueGuards = []
                         , retTerm           = retTerm
                         , retTermName       = retTermName
                         , lexicalScopes     = []
                         , lsCtr             = 0
                         , fsPrefix          = prefix
                         }
  return $ fsEnterLexScope fs

-- | Internal state of the compiler for code generation
data CompilerState = CompilerState { callStack         :: [FunctionScope]
                                   , globals           :: LexScope
                                   , funs              :: M.Map FunctionName CFunDef
                                   , typedefs          :: M.Map VarName Type
                                   , loopBound         :: Int
                                   , prefix            :: [String]
                                   , fnCtr             :: Int
                                   , findUB            :: Bool
                                   , values            :: Maybe (M.Map String Dynamic)
                                   -- Used for inputs that have no value.
                                   , defaultValue      :: Maybe Integer
                                   }

newtype Compiler a = Compiler (StateT CompilerState Mem a)
    deriving (Functor, Applicative, Monad, MonadState CompilerState, MonadIO)


instance MonadFail Compiler where
  fail = error "FAILED"

---
--- Setup, monad functions, etc
---

emptyCompilerState :: CompilerState
emptyCompilerState = CompilerState { callStack    = []
                                   , globals      = lsWithPrefix "global"
                                   , funs         = M.empty
                                   , typedefs     = M.empty
                                   , loopBound    = 4
                                   , prefix       = []
                                   , findUB       = True
                                   , fnCtr        = 0
                                   , values       = Nothing
                                   , defaultValue = Nothing
                                   }

compilerRunOnTop :: (FunctionScope -> Compiler (a, FunctionScope)) -> Compiler a
compilerRunOnTop f = do
  s       <- get
  (r, s') <-
    f
    $ fromMaybe (error "Cannot run in function: no function!")
    $ listToMaybe
    $ callStack s
  modify $ \s -> s { callStack = s' : tail (callStack s) }
  return r

compilerRunInScope
  :: String
  -> (FunctionScope -> Compiler (a, FunctionScope))
  -> (LexScope -> Compiler (a, LexScope))
  -> Compiler a
compilerRunInScope var fF lF = do
  stack <- gets callStack
  case stack of
    top : rest | isJust (fsFindLexScopeOpt var top) -> do
      (r, top') <- fF top
      modify $ \s -> s { callStack = top' : rest }
      return r
    _ -> do
      global       <- gets globals
      (r, global') <- lF global
      modify $ \s -> s { globals = global' }
      return r

compilerModifyInScope
  :: VarName
  -> (FunctionScope -> FunctionScope)
  -> (LexScope -> LexScope)
  -> Compiler ()
compilerModifyInScope v fF lF =
  compilerRunInScope v (return . ((), ) . fF) (return . ((), ) . lF)

compilerGetsInScope
  :: String -> (FunctionScope -> a) -> (LexScope -> a) -> Compiler a
compilerGetsInScope var fF lF = do
  stack <- gets callStack
  case stack of
    top : rest | isJust (fsFindLexScopeOpt var top) -> return $ fF top
    _ -> lF <$> gets globals

compilerGetsFunction :: (FunctionScope -> a) -> Compiler a
compilerGetsFunction f = compilerRunOnTop (\s -> return (f s, s))

compilerModifyTopM :: (FunctionScope -> Compiler FunctionScope) -> Compiler ()
compilerModifyTopM f = compilerRunOnTop $ fmap ((), ) . f

compilerModifyTop :: (FunctionScope -> FunctionScope) -> Compiler ()
compilerModifyTop f = compilerModifyTopM (return . f)

compilerGetsTop :: (FunctionScope -> a) -> Compiler a
compilerGetsTop f = compilerRunOnTop (\s -> return (f s, s))

declareVar :: VarName -> Type -> Compiler ()
declareVar var ty = do
  --liftIO $ putStrLn $ "declareVar: " ++ var ++ ": " ++ show ty
  isGlobal <- gets (null . callStack)
  if isGlobal
    then do
      g  <- gets globals
      g' <- liftMem $ lsDeclareVar var ty g
      modify $ \s -> s { globals = g' }
    else compilerModifyTopM $ \s -> liftMem $ fsDeclareVar var ty s

getVer :: VarName -> Compiler Version
getVer v = compilerGetsInScope v (fsGetVer v) (lsGetVer v)

nextVer :: VarName -> Compiler ()
nextVer v = compilerRunInScope v
                               (return . ((), ) . fsNextVer v)
                               (return . ((), ) . lsNextVer v)

getType :: VarName -> Compiler Type
getType v = compilerGetsInScope v (fsGetType v) (lsGetType v)

getSsaVar :: VarName -> Compiler SsaVar
getSsaVar v = compilerGetsInScope v (fsGetSsaVar v) (lsGetSsaVar v)

getNextSsaVar :: VarName -> Compiler SsaVar
getNextSsaVar v = compilerGetsInScope v (fsGetNextSsaVar v) (lsGetNextSsaVar v)

getSsaName :: VarName -> Compiler String
getSsaName n = ssaVarAsString <$> getSsaVar n

computingValues :: Compiler Bool
computingValues = gets (isJust . values)

getValues :: Compiler (M.Map String Dynamic)
getValues = gets $ fromMaybe (error "Not computing values") . values

modValues
  :: (M.Map String Dynamic -> Compiler (M.Map String Dynamic)) -> Compiler ()
modValues f = do
  s <- get
  case values s of
    Just vs -> do
      vs' <- f vs
      put $ s { values = Just vs' }
    Nothing -> return ()


smtEval :: Ty.SortClass s => Ty.Term s -> Compiler (Ty.Value s)
smtEval smt = flip Ty.eval smt <$> getValues

smtEvalBool :: Ty.TermBool -> Compiler Bool
smtEvalBool smt = Ty.valAsBool <$> smtEval smt

setValue :: VarName -> CTerm -> Compiler ()
setValue name cterm = modValues $ \vs -> do
  var <- ssaVarAsString <$> getSsaVar name
  --liftIO $ putStrLn $ var ++ " -> " ++ show cterm
  val <- liftMem $ ctermEval vs cterm
  return $ M.insert var val vs

setRetValue :: CTerm -> Compiler ()
setRetValue cterm = modValues $ \vs -> do
  var <- compilerGetsTop retTermName
  val <- liftMem $ ctermEval vs cterm
  return $ M.insert var val vs

getTerm :: VarName -> Compiler CTerm
getTerm var = compilerGetsInScope var (fsGetTerm var) (lsGetTerm var)

setTerm :: VarName -> CTerm -> Compiler ()
setTerm n v = compilerModifyInScope n (fsSetTerm n v) (lsSetTerm n v)

printComp :: Compiler ()
printComp = gets callStack >>= liftIO . traverse_ printFs

enterLexScope :: Compiler ()
enterLexScope = compilerModifyTop fsEnterLexScope

exitLexScope :: Compiler ()
exitLexScope = compilerModifyTop fsExitLexScope

pushGuard :: Ty.TermBool -> Compiler ()
pushGuard = compilerModifyTop . fsPushGuard

popGuard :: Compiler ()
popGuard = compilerModifyTop fsPopGuard

guarded :: Ty.TermBool -> Compiler a -> Compiler a
guarded cond action = pushGuard cond *> action <* popGuard

getGuard :: Compiler Ty.TermBool
getGuard = compilerGetsTop fsCurrentGuard

doReturn :: CTerm -> Compiler ()
doReturn value = compilerModifyTopM (fsReturn value)

getReturn :: Compiler CTerm
getReturn = compilerGetsTop retTerm

liftMem :: Mem a -> Compiler a
liftMem = Compiler . lift

liftAssert :: Assert a -> Compiler a
liftAssert = liftMem . Mem.liftAssert

runCodegen
  :: Bool -- ^ wether to check for UB
  -> Compiler a       -- ^ Codegen computation
  -> Assert (a, CompilerState)
runCodegen checkUB (Compiler act) =
  Mem.evalMem $ runStateT act $ emptyCompilerState { findUB = checkUB }

evalCodegen :: Bool -> Compiler a -> Assert a
evalCodegen checkUB act = fst <$> runCodegen checkUB act

execCodegen :: Bool -> Compiler a -> Assert CompilerState
execCodegen checkUB act = snd <$> runCodegen checkUB act


-- Turning VarNames (the AST's representation of a variable) into other representations
-- of variables

codegenVar :: VarName -> Compiler SsaVar
codegenVar var = SsaVar var <$> getVer var

-- | Human readable name.
-- We probably want to replace this with something faster (eg hash) someday, but
-- this is great for debugging
ssaVarAsString :: SsaVar -> String
ssaVarAsString (SsaVar varName ver) = varName ++ "_v" ++ show ver

whenM :: Monad m => m Bool -> m () -> m ()
whenM condition action = condition >>= flip when action

-- Assert that the current version of `var` is assign `value` to it.
argAssign :: VarName -> CTerm -> Compiler CTerm
argAssign var val = do
  --liftIO $ putStrLn $ "argAssign " ++ var ++ " = " ++ show val
  priorTerm  <- getTerm var
  ty         <- getType var
  trackUndef <- gets findUB
  ssaVar     <- getSsaVar var
  let castVal = cppCast ty val
  t <- liftMem $ cppDeclInitVar trackUndef ty (ssaVarAsString ssaVar) castVal
  setTerm var t
  whenM computingValues $ setValue var castVal
  return t

-- Bump the version of `var` and assign `value` to it.
ssaAssign :: VarName -> CTerm -> Compiler CTerm
ssaAssign var val = do
  --liftIO $ putStrLn $ "ssaAssign " ++ var ++ " = " ++ show val
  priorTerm  <- getTerm var
  ty         <- getType var
  nextSsaVar <- getNextSsaVar var
  guard      <- getGuard
  let guardTerm = CTerm (CBool guard) (Ty.BoolLit False)
      castVal   = cppCast ty val
      guardVal  = cppCond guardTerm castVal priorTerm
  trackUndef <- gets findUB
  t          <- liftMem
    $ cppDeclInitVar trackUndef ty (ssaVarAsString nextSsaVar) guardVal
  nextVer var
  setTerm var t
  whenM computingValues $ do
    g <- smtEvalBool guard
    setValue var (if g then castVal else priorTerm)
  return t

initAssign :: VarName -> Integer -> Compiler ()
initAssign name value = do
  ty <- getType name
  setValue name (ctermInit ty value)

initValues :: Compiler ()
initValues = modify $ \s -> s { values = Just M.empty }

setDefaultValueZero :: Compiler ()
setDefaultValueZero = modify $ \s -> s { defaultValue = Just 0 }

---
--- Functions
---

pushFunction :: FunctionName -> Type -> Compiler ()
pushFunction name ty = do
  p <- gets prefix
  c <- gets fnCtr
  let p' = name : p
  fs <- liftMem
    $ fsWithPrefix ("f" ++ show c ++ "_" ++ intercalate "_" (reverse p')) ty
  modify (\s -> s { prefix = p', callStack = fs : callStack s, fnCtr = c + 1 })

-- Pop a function, returning the return term
popFunction :: Compiler ()
popFunction =
  modify (\s -> s { callStack = tail (callStack s), prefix = tail (prefix s) })

registerFunction :: FunctionName -> CFunDef -> Compiler ()
registerFunction name function = do
  s0 <- get
  case M.lookup name $ funs s0 of
    Nothing -> put $ s0 { funs = M.insert name function $ funs s0 }
    _       -> error $ unwords ["Already declared", name]

getFunction :: FunctionName -> Compiler CFunDef
getFunction funName = do
  functions <- gets funs
  case M.lookup funName functions of
    Just function -> return function
    Nothing       -> error $ unwords ["Called undeclared function", funName]

---
--- Typedefs
---

typedef :: VarName -> Type -> Compiler ()
typedef name ty = modify $ \s -> case M.lookup name (typedefs s) of
  Nothing -> s { typedefs = M.insert name ty $ typedefs s }
  Just t  -> error $ unwords ["Already td'd", name, "to", show t]

untypedef :: VarName -> Compiler (Maybe Type)
untypedef name = M.lookup name <$> gets typedefs

---
--- If-statements
---

safeNary :: Ty.TermBool -> Ty.BoolNaryOp -> [Ty.TermBool] -> Ty.TermBool
safeNary id op xs = case xs of
  []  -> id
  [s] -> s
  _   -> Ty.BoolNaryExpr op xs

-- Loops

getLoopBound :: Compiler Int
getLoopBound = gets loopBound

setLoopBound :: Int -> Compiler ()
setLoopBound bound = modify (\s -> s { loopBound = bound })

-- UB

getAssignment :: Compiler (CTerm -> CTerm -> (Ty.TermBool, CTerm))
getAssignment = cppAssignment <$> gets findUB
