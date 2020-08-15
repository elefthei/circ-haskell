{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE GADTs #-}
module Codegen.C.CUtilsTest where
import           BenchUtils
import           Test.Tasty.HUnit
import           Codegen.C.CUtils
import qualified Codegen.C.Memory              as Mem
import qualified IR.SMT.TySmt as Ty
import qualified AST.Simple                    as AST
import qualified IR.SMT.Assert                 as Assert
import qualified Data.Map.Strict               as M

cutilsTest :: BenchTest
cutilsTest = benchTestGroup
  "CUtils"
  [ benchTestCase "new var" $ do
    a <- Assert.execAssert $ Mem.execMem $ do
      Mem.initMem
      Mem.liftAssert $ newVar AST.U8 "my_u8"
    (2 + 1) @=? M.size (Assert.vars a)
  , benchTestCase "new vars" $ do
    a <- Assert.execAssert $ Mem.execMem $ do
      Mem.initMem
      _ <- Mem.liftAssert $ newVar AST.U8 "my_u8"
      Mem.liftAssert $ newVar AST.S8 "my_i8"
    (2 + 2 + 1) @=? M.size (Assert.vars a)
  , benchTestCase "cppAdd: u8 + i8 = i8" $ do
    a <- Assert.evalAssert $ Mem.evalMem $ do
      Mem.initMem
      u <- Mem.liftAssert $ newVar AST.U8 "my_u8"
      i <- Mem.liftAssert $ newVar AST.S8 "my_i8"
      return $ cppAdd u i
    AST.S8 @=? cppType a
  , benchTestCase "cppAdd: i32 + i8 = i32" $ do
    a <- Assert.evalAssert $ Mem.evalMem $ do
      Mem.initMem
      u <- Mem.liftAssert $ newVar AST.S32 "my_i32"
      i <- Mem.liftAssert $ newVar AST.S8 "my_i8"
      return $ cppAdd u i
    AST.S32 @=? cppType a
    let (_, w, bv) = asInt $ term a
    Ty.SortBv w @=? Ty.sort bv
  , benchTestCase "cppNeg: -u8 = i8" $ do
    a <- Assert.evalAssert $ Mem.evalMem $ do
      Mem.initMem
      u <- Mem.liftAssert $ newVar AST.U8 "my_u8"
      return $ cppNeg u
    AST.S8 @=? cppType a
  , benchTestCase "cppNot: !u8 = bool" $ do
    a <- Assert.evalAssert $ Mem.evalMem $ do
      Mem.initMem
      u <- Mem.liftAssert $ newVar AST.U8 "my_u8"
      return $ cppNot u
    AST.Bool @=? cppType a
  , benchTestCase "cppCond: bool ? u8 : i8 = u8" $ do
    a <- Assert.evalAssert $ Mem.evalMem $ do
      Mem.initMem
      u <- Mem.liftAssert $ newVar AST.U8 "my_u8"
      i <- Mem.liftAssert $ newVar AST.S8 "my_i8"
      b <- Mem.liftAssert $ newVar AST.Bool "my_bool"
      return $ cppCond b u i
    AST.U8 @=? cppType a
  , benchTestCase "cppStore + cppLoad preserves type and size of u8" $ do
    a <- Assert.evalAssert $ Mem.evalMem $ do
      Mem.initMem
      u <- Mem.liftAssert $ newVar AST.U8 "my_u8"
      p <- Mem.liftAssert $ newVar (AST.Ptr32 AST.U8) "my_u8_ptr"
      _ <- Mem.liftAssert $ cppAssign True p (cppIntLit AST.U32 0)
      _ <- cppStore p u (Ty.BoolLit True)
      cppLoad p
    let (_, w, bv) = asInt $ term a
    Ty.SortBv w @=? Ty.sort bv
    AST.U8 @=? cppType a
  , benchTestCase "cppStore + cppLoad preserves type and size of *u8" $ do
    a <- Assert.evalAssert $ Mem.evalMem $ do
      Mem.initMem
      u <- Mem.liftAssert $ newVar (AST.Ptr32 AST.U8) "my_u8_ptr"
      p <- Mem.liftAssert $ newVar (AST.Ptr32 (AST.Ptr32 AST.U8)) "my_u8_ptr_ptr"
      _ <- Mem.liftAssert $ cppAssign True p (cppIntLit AST.U32 0)
      _ <- cppStore p u (Ty.BoolLit True)
      cppLoad p
    Ty.SortBv 32 @=? Ty.sort (snd $ asPtr $ term a)
    (AST.Ptr32 AST.U8) @=? cppType a
  ]