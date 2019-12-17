{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Codegen.CompilerMonad where
import           AST.Simple
import           Control.Monad.Fail
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Data.List                  (isInfixOf)
import qualified Data.Map                   as M
import           IR.SMT
import           Targets.SMT
import qualified Z3.Monad                   as Z

{-|

Module that defines the Compiler monad, the monad that keeps track of all internal
state for code generation. This state includes:
WHAT

There are many bits of low-hanging optimization fruit here. For example, we are doing
redundant state lookups, and storing lists of function names instead of a hash of
such a thing.

-}

type Version = Int
-- | Variable name and de-ambiguating caller context information.
-- This way, you can have two variables name 'foo' in different functions
-- and everything will still work.
-- Right now, we do this via the entire callstack, but we should actually just hash it.
data ASTVar = ASTVar VarName [FunctionName]
            deriving (Eq, Ord, Show)

data CodegenVar = CodegenVar ASTVar Version
                deriving (Eq, Ord, Show)

-- | Internal state of the compiler for code generation
data CompilerState = CompilerState { -- Mapping AST variables to information
                                     vers             :: M.Map ASTVar Version
                                   , tys              :: M.Map ASTVar Type
                                     -- Codegen context information
                                   , callStack        :: [FunctionName]
                                   , conditionalGuard :: Maybe Node
                                     -- SMT variables and memory
                                   , vars             :: M.Map CodegenVar SMTNode
                                   }

newtype Compiler a = Compiler (StateT CompilerState SMT a)
    deriving (Functor, Applicative, Monad, MonadState CompilerState, MonadIO)

instance Z.MonadZ3 Compiler where
    getSolver = Compiler $ lift $ Z.getSolver
    getContext = Compiler $ lift $ Z.getContext

instance MonadFail Compiler where
    fail = error "FAILED"

---
--- Setup, monad functions, etc
---

emptyCompilerState :: CompilerState
emptyCompilerState = CompilerState M.empty M.empty [] Nothing M.empty

liftSMT :: SMT a -> Compiler a
liftSMT = Compiler . lift

runCodegen :: Maybe Integer -- ^ Optional timeout
           -> Compiler a       -- ^ Codegen computation
           -> IO (a, CompilerState)
runCodegen mTimeout (Compiler act) = evalSMT mTimeout $ runStateT act emptyCompilerState

evalCodegen :: Maybe Integer -> Compiler a -> IO a
evalCodegen mt act = fst <$> runCodegen mt act

execCodegen :: Maybe Integer -> Compiler a -> IO CompilerState
execCodegen mt act = snd <$> runCodegen mt act

runSolverOnSMT :: Compiler SMTResult
runSolverOnSMT = liftSMT runSolver

---
---
---

-- Turning VarNames (the AST's representation of a variable) into other representations
-- of variables

-- | Take a VarName (the AST's representation of a variable) and turn it into an
-- ASTVar---a variable that can be distinguished from other variables of the same
-- name by its caller context.
astVar :: VarName -> Compiler ASTVar
astVar varName = do
  stack <- callStack `liftM` get
  return $ ASTVar varName stack

codegenVar :: VarName -> Compiler CodegenVar
codegenVar varName = do
  var <- astVar varName
  ver <- getVer varName
  return $ CodegenVar var ver

codegenToName :: CodegenVar -> String
codegenToName (CodegenVar (ASTVar varName allFuns) ver) = varName ++ show allFuns ++ show ver

---
---
---

-- | Declare a new variable, or error if the variable is already declared.
-- This adds the variable's version information (for SSA-ing) and type information
-- to the compiler state.
declareVar :: VarName -> Type -> Compiler ()
declareVar varName ty = do
  var <- astVar varName
  s0 <- get
  let allVers = vers s0
      allTys  = tys s0
  case M.lookup var allVers of
    Nothing -> put $ s0 { vers = M.insert var 0 allVers
                        , tys = M.insert var ty allTys
                        }
    _       -> error $ unwords ["Already declared", varName, "in current scope"]

-- | Bump the given variable up in version (for SSA)
nextVer :: VarName -> Compiler ()
nextVer varName = do
  var <- astVar varName
  s0 <- get
  let allVers = vers s0
  case M.lookup var allVers of
    Just ver -> put $ s0 { vers = M.insert var (ver + 1) allVers }
    _ -> error $ unwords ["Cannot increment version of undeclared", varName]

-- | Get the current version of the variable
getVer :: VarName -> Compiler Version
getVer varName = do
  var <- astVar varName
  allVers <- vers `liftM` get
  case M.lookup var allVers of
    Just ver -> return ver
    _        -> error $ unwords ["Cannot get version of undeclared", varName]

-- | Get the C++ type of the variable
getType :: VarName -> Compiler Type
getType varName = do
  var <- astVar varName
  allTys <- tys `liftM` get
  case M.lookup var allTys of
    Just ty -> return ty
    _       -> error $ unwords ["Cannot get type of undeclared", varName]

-- | Get an SMT node representing the given var
getNodeFor :: VarName -> Compiler SMTNode
getNodeFor varName = do
  var <- codegenVar varName
  s0 <- get
  let allVars = vars s0
  case M.lookup var allVars of
    Just node -> return node
    Nothing -> do
      ty <- getType varName
      node <- liftSMT $ newSMTVar ty $ codegenToName var
      put $ s0 { vars = M.insert var node allVars }
      return node
