module AST.Simple ( module AST.Simple
                  , module AST.Typed
                  ) where
import           AST.Typed
import           Prelude   hiding (Num)

{-|

This module presents a simple version of a C AST.
You can parse it using your own parser, map to it from a different AST, or just
write it raw for testing.

-}

---
--- Types
---

-- | General types: for now, signed or unsigned integers of
-- a certain width, bools, or double-precision floats
data Type = U8 | S8
          | U16 | S16
          | U32 | S32
          | U64 | S64
          | Bool
          | Double
          | Ptr64 Type
          | Ptr32 Type
          | Struct [(String, Type)]
          | Array (Maybe Int) Type
          | Void
          | Char
          | Float
          deriving (Eq, Ord, Show)

isIntegerType :: Type -> Bool
isIntegerType ty = isSignedInt ty || isUnsignedInt ty

makeType :: Int -> Bool -> Type
makeType numBits isSigned =
  case numBits of
    8  | isSigned -> S8
    8  -> U8
    16 | isSigned -> S16
    16 -> U16
    32 | isSigned -> S32
    32 -> U32
    64 | isSigned -> S64
    64 -> U64
    _  -> error "Unexpected width to makeType"

instance Typed Type where
  numBits U8             = 8
  numBits S8             = 8
  numBits U16            = 16
  numBits S16            = 16
  numBits U32            = 32
  numBits S32            = 32
  numBits U64            = 64
  numBits S64            = 64
  numBits Bool           = 1
  numBits Double         = 64
  numBits Ptr64{}        = 64
  numBits Ptr32{}        = 32
  numBits (Struct tys)   = sum $ map (numBits . snd) tys
  numBits (Array (Just num) ty) = num * numBits ty
  numBits (Array Nothing ty) = 32

  isSignedInt S8  = True
  isSignedInt S16 = True
  isSignedInt S32 = True
  isSignedInt S64 = True
  isSignedInt _   = False
  isUnsignedInt U8  = True
  isUnsignedInt U16 = True
  isUnsignedInt U32 = True
  isUnsignedInt U64 = True
  isUnsignedInt _   = False
  isDouble Double = True
  isDouble _      = False
  isFloat Float  = True
  isFloat _      = False
  isPointer Ptr64{} = True
  isPointer Ptr32{} = True
  isPointer _       = False

  isStruct Struct{} = True
  isStruct _        = False

  isArray Array{} = True
  isArray _       = False

  pointeeType (Ptr64 ty) = ty
  pointeeType (Ptr32 ty) = ty
  pointeeType v          = error $ unwords ["Can't get pointee type of non-pointer", show v]

  arrayBaseType (Array _ ty) = ty
  arrayBaseType a            =
      error $ unwords ["Cannot call arrayBaseType on non-array", show a]

  arrayNumElems (Array (Just n) _) = n
  arrayNumElems n           =
      error $ unwords ["Cannot call array num elems on non-array type", show n]

  structFieldTypes (Struct tys) = map snd tys
  structFieldTypes s =
      error $ unwords ["Cannot call structFieldTypes on non-struct", show s]

  structFieldList (Struct tys) = tys
  structFieldList s =
      error $ unwords ["Cannot call structFieldList on non-struct", show s]

  newStructType = Struct
  newArrayType = Array . Just

int8, int16, int32, int64 :: Type -> Bool
int8 S8 = True
int8 U8 = True
int8 _  = False
int16 S16 = True
int16 U16 = True
int16 _   = False
int32 S32     = True
int32 U32     = True
int32 Ptr32{} = True
int32 _       = False
int64 S64     = True
int64 U64     = True
int64 Ptr64{} = True
int64 _       = False

---
--- Variables
---

-- | Variables have names. Right now, a name is just a string, but we
-- may switch this type out later for better performance (e.g., to word)
type VarName = String

-- | A variable has a name and a type. SSA-ing happens in codegen, *not* in the AST
data Var = Var { varTy   :: Type
               , varName :: VarName
               }
           deriving (Eq, Ord, Show)

---
--- Numbers
---

-- | I'm seperating out the different types of numbers here, especially because
-- proof system code will want a variety of interesting number types (or, for that matter,
-- crypto code for symexing). Representing all these numbers with a single Haskell type
-- is not realistic, so we wrap the number type in an ADT
data Num = INum { numTy  :: Type
                , numVal :: Integer
                }
         | FNum { numTy    :: Type
                , floatVal :: Double
                }
         deriving (Eq, Ord, Show)

---
--- Struct and array literals
---

data StructLit = StructLit { structTy    :: Type
                           , structElems :: [Expr]
                           }
               deriving (Eq, Ord, Show)

data ArrayLit = ArrayLit { arrayTy    :: Type
                         , arrayElems :: [Expr]
                         }
              deriving (Eq, Ord, Show)

---
--- AST definition
---

-- | An AST expression: link
data Expr = VarExpr { varExpr :: Var }
          | NumExpr { numExpr :: Num }
          | StructExpr { structExpr :: StructLit }
          | ArrayExpr { arrayExpr :: ArrayLit }
          | Neg Expr
          | Not Expr
          | Abs Expr
          | Eq Expr Expr
          | NEq Expr Expr
          | And Expr Expr
          | Add Expr Expr
          | Sub Expr Expr
          | Mul Expr Expr
          | Or Expr Expr
          | XOr Expr Expr
          | Min Expr Expr
          | Max Expr Expr
          | Gt Expr Expr
          | Gte Expr Expr
          | Lt Expr Expr
          | Lte Expr Expr
          | Shl Expr Expr
          | Shr Expr Expr
          | Access { struct :: Expr
                   , field  :: Int
                   }
          | PtrAccess { struct :: Expr
                      , field  :: Int
                      }
          | Index { array :: Expr
                  , index :: Expr
                  }
          | PtrIndex { array :: Expr
                     , index :: Expr
                     }
          | Tern Expr Expr Expr
          | Cast Expr Type
          | Call FunctionName [Expr]
          | Load Expr
            deriving (Eq, Ord, Show)

isAccess :: Expr -> Bool
isAccess Access{} = True
isAccess _        = False

isIndex :: Expr -> Bool
isIndex Index{} = True
isIndex _       = False

isPtrAccess :: Expr -> Bool
isPtrAccess PtrAccess{} = True
isPtrAccess _           = False

isPtrIndex :: Expr -> Bool
isPtrIndex PtrIndex{} = True
isPtrIndex _          = False

isVar :: Expr -> Bool
isVar VarExpr{} = True
isVar _         = False

-- | An AST statement: link
data Stmt = Decl Var
          | Assign Var Expr
          | Store Expr Expr
          | If Expr [Stmt] [Stmt]
          | While Expr [Stmt]
          | VoidCall FunctionName [Expr]
          | Return Expr
          | VoidReturn

---
--- Functions and programs
---

type FunctionName = String

data Function = Function { fName :: FunctionName
                         , fTy   :: Type
                         , fArgs :: [(VarName, Type)]
                         , fBody :: [Stmt]
                         }

-- | A program is function definitions and class definitions
data Program = Program { functions :: [Function] }


