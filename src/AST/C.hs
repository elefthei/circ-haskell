module AST.C where
import           AST.Simple
import           Data.Maybe            (isJust)
import           Language.C.Data.Ident
import           Language.C.Syntax.AST

bodyFromFunc :: CFunctionDef a -> CStatement a
bodyFromFunc (CFunDef _ _ _ stmt _) = stmt

argsFromFunc :: (Show a) => CFunctionDef a -> [CDeclaration a]
argsFromFunc (CFunDef _ decl _ _ _) =
  case derivedFromDecl decl of
    (CFunDeclr (Right decls) _ _):_ -> fst decls
    f ->
      error $ unwords ["Expected function declaration but got", show f]

derivedFromDecl :: CDeclarator a -> [CDerivedDeclarator a]
derivedFromDecl (CDeclr _ derived _ _ _) = derived

ctypeToType :: (Show a) => [CTypeSpecifier a] -> Type
ctypeToType ty = case ty of
                   [CVoidType{}]   -> Void
                   [CCharType{}]   -> Char
                   [CIntType{}]    -> S32
                   [CFloatType{}]  -> Float
                   [CDoubleType{}] -> Double
                   [ty] -> error $ unwords  ["Unexpected type", show ty]
                   [CLongType{}, CUnsigType{}, CIntType{}] -> U64
                   ty -> error $ unwords ["Unexpected type", show ty]

identFromDecl :: CDeclarator a -> Ident
identFromDecl (CDeclr mIdent _ _ _ _) = case mIdent of
                                          Nothing -> error "Expected identifier in declarator"
                                          Just i  -> i

identToVarName :: Ident -> String
identToVarName (Ident name _ _) = name

specToStorage :: (Show a) => CDeclarationSpecifier a -> CStorageSpecifier a
specToStorage spec =
  case spec of
    CStorageSpec s -> s
    s              -> error $ unwords ["Expected storage specifier in declaration", show s]

specToType :: CDeclarationSpecifier a -> CTypeSpecifier a
specToType spec = case spec of
                    CTypeSpec ts -> ts
                    _            -> error "Expected type specificer in declaration"

-- Declaration specifiers

isStorageSpec :: CDeclarationSpecifier a -> Bool
isStorageSpec CStorageSpec{} = True
isStorageSpec _              = False

storageFromSpec :: CDeclarationSpecifier a -> CStorageSpecifier a
storageFromSpec (CStorageSpec spec) = spec
storageFromSpec _                   = error "Expected storage specifier"

isTypeSpec :: CDeclarationSpecifier a -> Bool
isTypeSpec CTypeSpec{} = True
isTypeSpec _           = False

typeFromSpec :: CDeclarationSpecifier a -> CTypeSpecifier a
typeFromSpec (CTypeSpec spec) = spec
typeFromSpec _                = error "Expected type specifier"

isTypeQual :: CDeclarationSpecifier a -> Bool
isTypeQual CTypeQual{} = True
isTypeQual _           = False

qualFromSpec :: CDeclarationSpecifier a -> CTypeQualifier a
qualFromSpec (CTypeQual spec) = spec
qualFromSpec _                = error "Expected type qualifier"

isFuncSpec :: CDeclarationSpecifier a -> Bool
isFuncSpec CFunSpec{} = True
isFuncSpec _          = False

funcFromSpec :: CDeclarationSpecifier a -> CFunctionSpecifier a
funcFromSpec (CFunSpec spec) = spec
funcFromSpec _               = error "Expected function specifier"

isAlignSpec :: CDeclarationSpecifier a -> Bool
isAlignSpec CAlignSpec{} = True
isAlignSpec _            = False

alignFromSpec :: CDeclarationSpecifier a -> CAlignmentSpecifier a
alignFromSpec (CAlignSpec spec) = spec
alignFromSpec _                 = error "Expected alignment specifier"

-- Storage specifiers

isAuto :: CStorageSpecifier a -> Bool
isAuto CAuto{} = True
isAuto _       = False

isRegister :: CStorageSpecifier a -> Bool
isRegister CRegister{} = True
isRegister _           = False

isStatic :: CStorageSpecifier a -> Bool
isStatic CStatic{} = True
isStatic _         = False

isExtern :: CStorageSpecifier a -> Bool
isExtern CExtern{} = True
isExtern _         = False

isTypedef :: CStorageSpecifier a -> Bool
isTypedef CTypedef{} = True
isTypedef _          = False

isThread :: CStorageSpecifier a -> Bool
isThread CThread{} = True
isThread _         = False

isKernelFn :: CStorageSpecifier a -> Bool
isKernelFn CClKernel{} = True
isKernelFn _           = False

isGlobal :: CStorageSpecifier a -> Bool
isGlobal CClGlobal{} = True
isGlobal _           = False

isLocal :: CStorageSpecifier a -> Bool
isLocal CClLocal{} = True
isLocal _          = False
