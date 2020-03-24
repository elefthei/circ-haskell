module Codegen.C where
import           AST.C
import           AST.Simple
import           Codegen.CompilerMonad
import           Control.Monad.State.Strict      (forM, forM_, liftIO, unless,
                                                  void, when)
import           Data.Maybe                      (fromJust, isJust, isNothing)
import           IR.SMT
import           Language.C.Analysis.AstAnalysis
import           Language.C.Data.Ident
import           Language.C.Syntax.AST
import           Language.C.Syntax.Constants

fieldToInt :: Ident -> Int
fieldToInt = undefined

typedefSMT :: (Show a)
           => Ident
           -> [CDeclarationSpecifier a]
           -> [CDerivedDeclarator a]
           -> Compiler ()
typedefSMT (Ident name _ _) tys ptrs = typedef name $
                                       getTy (baseTypeFromSpecs tys) ptrs

declareVarSMT :: (Show a)
              => Ident
              -> [CDeclarationSpecifier a]
              -> [CDerivedDeclarator a]
              -> Compiler ()
declareVarSMT (Ident name _ _) tys ptrs = declareVar name $
                                          getTy (baseTypeFromSpecs tys) ptrs

genVarSMT :: Ident -> Compiler SMTNode
genVarSMT (Ident name _ _) = getNodeFor name

genNumSMT :: CConstant a -> Compiler SMTNode
genNumSMT c = case c of
  CIntConst (CInteger i _ _) _ -> liftIR $ newInt S32 i
  CCharConst (CChar c _) _     -> error ""
  CCharConst (CChars c _) _    -> error ""
  CFloatConst (CFloat str) _   -> error ""
  CStrConst (CString str _) _  -> error ""

genExprSMT :: CExpression a -> Compiler SMTNode
genExprSMT expr = case expr of
  CVar id _               -> genVarSMT id
  CConst c                -> genNumSMT c
  CAssign op lhs rhs _    -> do
    lhs' <- genExprSMT lhs
    rhs' <- genExprSMT rhs
    getAssignOp op lhs' rhs'
  CBinary op left right _ -> do
    left' <- genExprSMT left
    right' <- genExprSMT right
    getBinOp op left' right'
  CUnary op arg _ -> genExprSMT arg >>= getUnaryOp op
  CIndex arr index _ -> do
    arr' <- genExprSMT arr
    index' <- genExprSMT index
    liftIR $ getIdx arr' index'
  CMember struct field _ _ -> do
    struct' <- genExprSMT struct
    liftIR $ getField struct' $ fieldToInt field
  _                       -> error $ unwords [ "We do not support"
                                             , "right now"
                                             ]

getUnaryOp :: CUnaryOp -> SMTNode -> Compiler SMTNode
getUnaryOp op arg = liftIR $ case op of
  CPreIncOp -> error ""
    -- one <- bvNumOfWidth arg 1
    -- cppAdd one arg >>= smtAssign arg
    -- return arg
  -- cpredecop ->
  -- CPostIncOp ->
  -- CPostDecOp ->
  -- CAdrOp ->
  -- The '*' operation
  CIndOp    -> smtLoad arg
  CPlusOp   -> error $ unwords $ ["Do not understand:", show op]
  CMinOp    -> error $ unwords $ ["Do not understand:", show op]
  -- One's complement: NOT CORRECT
  CCompOp   -> cppNeg arg
  -- Logical negation: NOT CORRECT
  CNegOp    -> cppNeg arg

getBinOp :: CBinaryOp -> SMTNode -> SMTNode -> Compiler SMTNode
getBinOp op left right = liftIR $ case op of
  CMulOp -> cppMul left right
  -- CDivOp
  -- CRmdOp
  CAddOp -> cppAdd left right
  CSubOp -> cppSub left right
  CShlOp -> cppShiftLeft left right
  CShrOp -> cppShiftRight left right
  CLeOp  -> cppLt left right
  CGrOp  -> cppGt left right
  CLeqOp -> cppLte left right
  CGeqOp -> cppGte left right
  CEqOp  -> cppEq left right
  CNeqOp -> cppEq left right >>= cppNeg
  CAndOp -> cppAnd left right
  CXorOp -> cppXor left right
  COrOp  -> cppOr left right
  -- CLndOp
  -- CLorOp

-- | Assign operation
-- eg x += 1
-- aka x = x + 1
getAssignOp :: CAssignOp -> SMTNode -> SMTNode -> Compiler SMTNode
getAssignOp op l r = case op of
  CAssignOp -> liftIR $ smtAssign l r >> return l
  CMulAssOp -> liftIR $ do
    result <- cppMul l r
    smtAssign l result >> return l
  -- CDivAssOp -> liftIR $ do
  --   result <- cppDiv l r
  --   smtAssign l result >> return l
  -- CRmdAssOp
  CAddAssOp -> liftIR $ do
    result <- cppAdd l r
    smtAssign l result >> return l
  CSubAssOp -> liftIR $ do
    result <- cppSub l r
    smtAssign l result >> return l
  CShlAssOp -> liftIR $ do
    result <- cppShiftLeft l r
    smtAssign l result >> return l
  CShrAssOp -> liftIR $ do
    result <- cppShiftRight l r
    smtAssign l result >> return l
  CAndAssOp -> liftIR $ do
    result <- cppAnd l r
    smtAssign l result >> return l
  CXorAssOp -> liftIR $ do
    result <- cppXor l r
    smtAssign l result >> return l
  COrAssOp -> liftIR $ do
    result <- cppOr l r
    smtAssign l result >> return l

---
--- Statements
---

genStmtSMT :: (Show a) => CStatement a -> Compiler ()
genStmtSMT stmt = case stmt of
  CCompound ids items _ ->
    forM_ items $ \item -> do
      case item of
        CBlockStmt stmt -> error "many stmt"--genStmtSMT stmt
        CBlockDecl decl -> genDeclSMT decl
        CNestedFunDef{} -> error "Nested function definitions not supported"
  CExpr{}               -> liftIO $ print "expr"
  CIf{}                 -> liftIO $ print "if"
  CWhile{}              -> liftIO $ print "while"
  CFor{}                -> liftIO $ print "while"
  _                     -> liftIO $ print "other"

genDeclSMT :: (Show a) => CDeclaration a -> Compiler ()
genDeclSMT (CDecl specs decls _) = do
  when (null specs) $ error "Expected specifier in declaration"
  let firstSpec     = head specs
      isTypedefDecl = (isStorageSpec firstSpec) && (isTypedef $ storageFromSpec firstSpec)
      baseType      = if isTypedefDecl then tail specs else specs

  forM_ decls $ \(Just dec, mInit, _) -> do
    let mName   = identFromDeclr dec
        name    = if isJust mName then fromJust mName else error "Expected identifier in decl"
        ptrType = derivedFromDeclr dec

    if isTypedefDecl
    then typedefSMT name baseType ptrType
    else do
      declareVarSMT name baseType ptrType
      case mInit of
        Just (CInitExpr e _) -> do
          lhs <- genVarSMT name
          rhs <- genExprSMT e
          liftIR $ smtAssign lhs rhs
        _                    -> return ()

---
--- High level codegen (translation unit, etc)
---

genFunDef :: (Show a) => CFunctionDef a -> Compiler ()
genFunDef f = do
  let args = argsFromFunc f
      body = bodyFromFunc f
  forM_ args genDeclSMT
  case body of
    CCompound{} -> genStmtSMT body
    _           -> error "Expected C statement block in function definition"

genAsm :: CStringLiteral a -> Compiler ()
genAsm = undefined

codegenC :: CTranslUnit -> Compiler ()
codegenC (CTranslUnit decls _) = do
  forM_ decls $ \decl -> case decl of
    CDeclExt decl -> genDeclSMT decl
    CFDefExt fun  -> genFunDef fun
    CAsmExt asm _ -> genAsm asm
