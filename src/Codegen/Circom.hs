{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
module Codegen.Circom ( genExpr
                      , genStatement
                      , genStatements
                      , genMain
                      , genMainCtx
                      , lcZero
                      , Ctx(..)
                      , Term(..)
                      , LTerm(..)
                      , Signal(..)
                      , Constraint
                      , LC
                      , ctxStore
                      , ctxGet
                      , ctxAddConstraint
                      , ctxWithEnv
                      ) where

import           AST.Circom                 as AST
import           Codegen.Circom.Constraints (Constraints)
import qualified Codegen.Circom.Constraints as CS
import           Codegen.Circom.Term        as Term
import           Control.Monad.State.Strict
import qualified Data.Bits                  as Bits
import           Data.Field.Galois          (Prime, fromP, toP)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 as Maybe
import           Data.Proxy                 (Proxy (Proxy))
import qualified Data.Set                   as Set
import           Debug.Trace                (trace)
import           GHC.TypeLits.KnownNat
import           GHC.TypeNats
import qualified IR.TySmt                   as Smt

intLog2 :: Integral a => a -> a
intLog2 n =
    if n <= fromInteger 1 then
        fromInteger 0
    else
        fromInteger 1 + intLog2 (n `div` fromInteger 2)

-- XXX(HACK): Log2 0 is actually undefined, but who wants to deal with that?
--            we treat it as 0, even though the type systems rejects it.
instance KnownNat x => KnownNat1 $(nameToSymbol ''Log2) x where
  natSing1 = SNatKn (intLog2 (natVal (Proxy @x)))
  {-# INLINE natSing1 #-}



-- Given a value, and dimensions, produces a multi-d array of size given by
-- dimensions, containing copies of the value.
termMultiDimArray :: KnownNat k => Term k -> [Term k] -> Term k
termMultiDimArray = foldr (\d acc -> case d of
        Base (Scalar n, _) -> Array $ replicate (fromIntegral $ fromP n) acc
        _                  -> error $ "Illegal dimension " ++ show d
    )

-- Given a signal name and dimensions, produces a multi-d array containing the
-- consituent signals
--
-- Kind of like "a" [2, 1] to [["a.0.0"], ["a.1.0"]]
termSignalArray :: forall k. KnownNat k => Ctx k -> String -> [Term k] -> (Ctx k, Term k)
termSignalArray ctx name dim = helper ctx name [] (integerizeDims dim)
  where
    integerizeDims :: [Term k] -> [Int]
    integerizeDims [] = []
    integerizeDims (t:ts) = case t of
        Base (Scalar n, _) -> fromIntegral (fromP n) : integerizeDims ts
        _ -> error $ "Illegal dimension " ++ show t

    helper :: Ctx k -> String -> [Int] -> [Int] -> (Ctx k, Term k)
    helper c name' location dims =
      case dims of
        [] -> (c', Base (Sig s, Smt.Var (show i)))
          where
            i = nextSignal c
            s = SigLocal name' (reverse location)
            c' = c { nextSignal = nextSignal c + 1, numberToSignal = (show i, s) : (numberToSignal c) }
        n : rest -> (c', Array (reverse ts))
          where
            (c', ts) = foldl folder (c, []) [0..(n-1)]
            folder :: (Ctx k, [Term k]) -> Int -> (Ctx k, [Term k])
            folder (ctxAcc, tAcc) i =
              let (ctxAcc', t') = helper ctxAcc name' (i:location) rest in
                (ctxAcc', t' : tAcc)


wireGenTimeConst :: WireBundle k -> Bool
wireGenTimeConst t = case t of
    Sig {}       -> False
    Quadratic {} -> False
    Scalar {}    -> True
    Linear {}    -> False
    Other        -> False

termGenTimeConst :: Term k -> Bool
termGenTimeConst t = case t of
    Base (b, _) -> wireGenTimeConst b
    Array a     -> all termGenTimeConst a
    Struct c    -> all termGenTimeConst $ env c

genGetUnMutOp :: KnownNat k => UnMutOp -> Term k -> Term k
genGetUnMutOp op = case op of
    PreInc  -> (+ Base (fromInteger 1))
    PostInc -> (+ Base (fromInteger 1))
    PreDec  -> (+ Base (fromInteger (-1)))
    PostDec -> (+ Base (fromInteger (-1)))
  where

genIndexedIdent :: KnownNat k => IndexedIdent -> CtxGen k LTerm
genIndexedIdent (i, dims) = do
  dimTerms <- sequence $ map genExprM dims
  return $ foldl attachDim (LTermIdent i) dimTerms
  where
    attachDim :: KnownNat k => LTerm -> Term k ->LTerm
    attachDim lTerm dimTerm = case dimTerm of
      Base (Scalar d, _) -> LTermIdx lTerm (fromIntegral $ fromP d)
      d -> error $ "Non-scalar " ++ show d ++ " as index in " ++ show dims


genLocation :: KnownNat k => Location -> CtxGen k LTerm
genLocation loc = case loc of
    LocalLocation a -> genIndexedIdent a
    ForeignLocation a b -> do
      at <- genIndexedIdent a
      bt <- genIndexedIdent b
      return $ embed at bt
      where
        embed item (LTermIdent s) = LTermPin item s
        embed item (LTermIdx x i) = LTermIdx (embed item x) i
        embed item (LTermPin x p) = LTermPin (embed item x) p

type PfTerm k = Smt.Term (Smt.PfSort k)
type IntTerm = Smt.Term Smt.IntSort
type BoolTerm = Smt.Term Smt.BoolSort

-- Lifts a fun: Integer -> Integer -> Integer to one that operates over gen-time constant
-- terms
liftToBaseTerm :: KnownNat k =>
    (Integer -> Integer -> Integer) ->
    (PfTerm k -> PfTerm k -> PfTerm k) ->
    BaseTerm k ->
    BaseTerm k ->
    BaseTerm k
liftToBaseTerm ft fsmt (sa, sb) (ta, tb) =
    ( case (sa, ta) of
        (Scalar c1 , Scalar c2) -> Scalar $ toP $ ft (fromP c1) (fromP c2)
        _                       -> Other
    , fsmt sb tb
    )

liftToTerm :: KnownNat k =>
    String ->
    (Integer -> Integer -> Integer) ->
    (PfTerm k -> PfTerm k -> PfTerm k) ->
    Term k ->
    Term k ->
    Term k
liftToTerm name f fsmt s t = case (s, t) of
    (a@Array {}, _) -> error $ "Cannot perform operation \"" ++ name ++ "\" on array term " ++ show a
    (a@Struct {}, _) -> error $ "Cannot perform operation \"" ++ name ++ "\" on struct term " ++ show a
    (Base a, Base b) -> Base $ liftToBaseTerm f fsmt a b
    (l, r) -> liftToTerm name f fsmt r l

liftBvToTerm :: forall k. KnownNat k =>
    String ->
    (Integer -> Integer -> Integer) ->
    Smt.BvBinOp ->
    Term k ->
    Term k ->
    Term k
liftBvToTerm name f op =
    liftToTerm name
               f
               (\a b -> Smt.IntToPf @k $ Smt.BvToInt $
                        -- Note that `k` is really too big, but it would take
                        -- moew work to convince GHC that Log2 k + 1 is a
                        -- KnownNat.
                        Smt.BvBinExpr op (Smt.IntToBv @(Log2 k + 1) $ Smt.PfToInt a)
                                         (Smt.IntToBv @(Log2 k + 1) $ Smt.PfToInt b))

liftIntFnToTerm :: forall k. KnownNat k =>
    String ->
    (Integer -> Integer -> Integer) ->
    (IntTerm -> IntTerm -> IntTerm) ->
    Term k ->
    Term k ->
    Term k
liftIntFnToTerm name f g =
    liftToTerm name
               f
               (\a b -> Smt.IntToPf $
                        g (Smt.PfToInt a)
                          (Smt.PfToInt b))

liftIntOpToTerm :: KnownNat k => String -> (Integer -> Integer -> Integer) -> Smt.IntBinOp -> Term k -> Term k -> Term k
liftIntOpToTerm name f op = liftIntFnToTerm name f (Smt.IntBinExpr op)

-- Lifts a fun: Integer -> Integer -> Bool to one that operates over gen-time constant
-- terms
liftCmpToTerm :: forall k. KnownNat k =>
    String ->
    (Integer -> Integer -> Bool) ->
    Smt.IntBinPred ->
    Term k ->
    Term k ->
    Term k
liftCmpToTerm name f g =
    liftIntFnToTerm name (\a b -> if f a b then 1 else 0)
                         (\a b -> Smt.BoolToInt $ Smt.IntBinPred g a b)

-- Lifts a fun: Bool -> Bool -> Bool to one that operates over gen-time
-- constant terms
liftBoolFnToTerm :: forall k. KnownNat k =>
    String ->
    (Bool -> Bool -> Bool) ->
    (BoolTerm -> BoolTerm -> BoolTerm) ->
    Term k ->
    Term k ->
    Term k
liftBoolFnToTerm name f g =
    liftToTerm name (\a b -> if f (a /= 0) (b /= 0) then 1 else 0)
                    (\a b -> Smt.IntToPf $ Smt.BoolToInt $ g
                        (Smt.PfBinPred Smt.PfNe z a)
                        (Smt.PfBinPred Smt.PfNe z b))
    where
        z = Smt.IntToPf $ Smt.IntLit 0

-- Lifts a fun: Integer -> Integer to one that operates over gen-time constant terms
liftUnToBaseTerm :: KnownNat k =>
    (Integer -> Integer) ->
    (PfTerm k -> PfTerm k) ->
    BaseTerm k ->
    BaseTerm k
liftUnToBaseTerm f fsmt (sa, sb) =
    ( case sa of
        Scalar c1 -> (Scalar . toP . f . fromP) c1
        _         -> Other
    , fsmt sb
    )


liftUnToTerm :: KnownNat k =>
    String ->
    (Integer -> Integer) ->
    (PfTerm k -> PfTerm k) ->
    Term k ->
    Term k
liftUnToTerm name f fsmt t = case t of
    a@Array {} -> error $ "Cannot perform operation \"" ++ name ++ "\" on array term " ++ show a
    a@Struct {} -> error $ "Cannot perform operation \"" ++ name ++ "\" on struct term " ++ show a
    Base a -> Base $ liftUnToBaseTerm f fsmt a

genExpr :: forall k. KnownNat k => Expr -> Ctx k -> (Term k, Ctx k)
genExpr = runCtxGen . genExprM

genExprM :: forall k. KnownNat k => Expr -> CtxGen k (Term k)
genExprM expr = case expr of
    NumLit i -> return $ Base $ fromInteger $ fromIntegral i
    ArrayLit es -> do
        ts <- genExprs es
        return $ Array ts
    BinExpr op l r -> do
      l' <- genExprM l
      r' <- genExprM r
      return $ case op of
        Add    -> l' + r'
        Sub    -> l' - r'
        Mul    -> l' * r'
        Div    -> l' / r'
        IntDiv -> liftIntOpToTerm "//" div  Smt.IntDiv l' r'
        Mod    -> liftIntOpToTerm "%"  mod  Smt.IntMod l' r'
        Lt     -> liftCmpToTerm "<"    (<)  Smt.IntLt  l' r'
        Gt     -> liftCmpToTerm ">"    (>)  Smt.IntGt  l' r'
        Le     -> liftCmpToTerm "<="   (<=) Smt.IntLe  l' r'
        Ge     -> liftCmpToTerm "<="   (>=) Smt.IntGe  l' r'
        Eq     -> liftCmpToTerm "=="   (==) Smt.IntEq  l' r'
        Ne     -> liftCmpToTerm "!="   (/=) Smt.IntNe  l' r'
        And    -> liftBoolFnToTerm "&&" (&&)
            (\a b -> Smt.BoolNaryExpr Smt.And [a, b]) l' r'
        Or     -> liftBoolFnToTerm "||" (||)
            (\a b -> Smt.BoolNaryExpr Smt.Or [a, b]) l' r'
        Shl    -> liftIntOpToTerm "<<" (liftShiftToInt Bits.shiftL) Smt.IntShl l' r'
        Shr    -> liftIntOpToTerm ">>" (liftShiftToInt Bits.shiftR) Smt.IntShr l' r'
        BitAnd -> liftBvToTerm "&" (Bits..&.) Smt.BvAnd l' r'
        BitOr  -> liftBvToTerm "|" (Bits..|.) Smt.BvOr  l' r'
        BitXor -> liftBvToTerm "^" Bits.xor   Smt.BvXor l' r'
        Pow    -> liftIntOpToTerm "**" (^) Smt.IntPow l' r'
      where
        liftShiftToInt :: (Integer -> Int -> Integer) -> Integer -> Integer -> Integer
        liftShiftToInt a b c = a b (fromIntegral c)
    UnExpr op e -> do
      t <- genExprM e
      return $ case op of
        UnNeg -> -t
        Not -> liftUnToTerm "!" (\c -> if c /= 0 then 0 else 1)
            (Smt.IntToPf . Smt.BoolToInt . Smt.Not . Smt.PfBinPred Smt.PfNe z) t
          where
            z = Smt.IntToPf $ Smt.IntLit 0
        UnPos -> case t of
            Array ts     -> Base $ fromInteger $ fromIntegral $ length ts
            Struct c     -> Base $ fromInteger $ fromIntegral $ Map.size $ env c
            _ -> t
        BitNot -> error "NYI" -- The sematics of this are unclear.
    UnMutExpr op loc -> genUnExpr op loc
    Ite c l r -> do
      condT <- genExprM c
      caseT <- genExprM l
      caseF <- genExprM r
      let z = Smt.IntToPf $ Smt.IntLit 0
      return $ case condT of
        Base (Scalar 0, _)     -> caseF
        Base (Scalar _, _)     -> caseT
        Base (_, v)            ->
          case (caseT, caseF) of
            (Base t, Base f) -> Base (Other, Smt.Ite (Smt.PfBinPred Smt.PfNe z v) (snd t) (snd f))
            (t, f) -> error $ "Cannot evalate a ternary as " ++ show t ++ " or " ++ show f
        t -> error $ "Cannot condition on term " ++ show t
    LValue loc -> do
      -- TODO(aozdemir): enforce no ctx change for sanity?
      lt <- genLocation loc
      gets (ctxGet lt)
    Call name args -> do
      (isFn, formalArgs, block) <- gets $ ctxGetCallable name
      actualArgs <- genExprs args
      c <- get
      let newCtx = c { env = Map.fromList (zip formalArgs actualArgs)
                     , constraints = CS.empty
                     }
      let postCtx = execCtxGen (genStatements block) newCtx
      if all termGenTimeConst actualArgs then
            if isFn then
                return $ Maybe.fromMaybe
                    (error $ "The function " ++ name ++ " did not return")
                    (returning postCtx)
            else
                do
                    modify (\c' -> c' { nextSignal = nextSignal postCtx })
                    return $ ctxToStruct postCtx
        else
            return $ error "Non-constant arguments to function!! NYI"
        where

genUnExpr :: KnownNat k => UnMutOp -> Location -> CtxGen k (Term k)
genUnExpr op loc = do
  lval <- genLocation loc
  term <- gets (ctxGet lval)
  let term' = genGetUnMutOp op term
  modify (ctxStore lval term')
  return $ case op of
    PostInc -> term
    PreInc  -> term'
    PostDec -> term
    PreDec  -> term'

genExprs :: KnownNat k => [Expr] -> CtxGen k [Term k]
genExprs = sequence . map genExprM

genStatements :: KnownNat k => [Statement] -> CtxGen k ()
genStatements = fmap (const ()) . sequence . map genStatementMOrReturn

genStatementMOrReturn :: KnownNat k => Statement -> CtxGen k ()
genStatementMOrReturn s = do
    c <- get
    if isJust (returning c) then
        return ()
    else
        genStatementM s

genStatement :: forall k. KnownNat k => Statement -> Ctx k -> Ctx k
genStatement = execCtxGen . genStatementM

genStatementM :: forall k. KnownNat k => Statement -> CtxGen k ()
genStatementM statement = case statement of
    -- Note, signals are immutable.
    Assign loc expr -> do
      lval <- genLocation loc
      term <- genExprM expr
      modify (ctxStore lval term)
    -- TODO Not quite right: evals twice
    OpAssign op loc expr -> genStatementM (Assign loc (BinExpr op (LValue loc) expr))
    Constrain l r -> do
      lt <- genExprM l
      rt <- genExprM r
      -- Construct the zero term
      let zt = lt - rt
      case zt of
        Base (Scalar 0, _) -> modify id
        Base (Sig s, _) -> modify $ ctxAddConstraint (lcZero, lcZero, sigAsLC s)
        Base (Linear lc, _) -> modify $ ctxAddConstraint (lcZero, lcZero, lc)
        Base (Quadratic a b c, _) -> modify $ ctxAddConstraint (a, b, c)
        _ -> error $ "Cannot constain " ++ show zt ++ " to zero"
    -- TODO Not quite right: evals twice
    AssignConstrain l e -> genStatements [Assign l e, Constrain (LValue l) e]
    VarDeclaration name dims ini -> do
      let z = Smt.IntToPf $ Smt.IntLit 0
      ts <- genExprs dims
      modify (ctxInit name (termMultiDimArray (Base (Scalar 0, z)) ts))
      case ini of
        Just e  -> genStatementM (Assign (LocalLocation (name, [])) e)
        Nothing -> modify id
    SigDeclaration name kind dims -> do
      ts <- genExprs dims
      c <- get
      let (c', t) = termSignalArray c name ts
      let c'' = Set.fold sigAdder c' (termSignals t)
      put c''
      modify $ ctxInit name t
      where
        sigAdder = if AST.isPublic kind then Term.ctxAddPublicSig else Term.ctxAddPrivateSig
    SubDeclaration name dims ini -> do
      let z = Smt.IntToPf $ Smt.IntLit 0
      ts <- genExprs dims
      modify (ctxInit name (termMultiDimArray (Base (Scalar 0, z)) ts))
      case ini of
        Just e  -> genStatementM (Assign (LocalLocation (name, [])) e)
        Nothing -> return ()
    If cond true false -> do
      tcond <- genExprM cond
      case tcond of
        Base (Scalar 0, _) -> genStatements $ concat $ Maybe.maybeToList false
        Base (Scalar _, _) -> genStatements true
        _ -> error $ "Invalid conditional term " ++ show tcond ++ " in " ++ show cond
    While cond block -> do
      tcond <- genExprM cond
      case tcond of
        Base (Scalar 0, _) -> modify id
        Base (Scalar _, _) -> do
          genStatements block
          genStatementM (While cond block)
        _ -> error $ "Invalid conditional term " ++ show tcond ++ " in " ++ show cond
    For ini cond step block -> genStatements [ini, While cond (block ++ [step])]
    DoWhile block expr -> genStatements (block ++ [While expr block])
    Compute _ -> return ()
    Ignore e -> do
      _ <- genExprM e
      return ()
    Log e -> do
      t <- genExprM e
      return $ trace (show e ++ ": " ++ show t) ()
    Return e -> do
      t <- genExprM e
      modify (\c -> c { returning = Just t })

genMain :: KnownNat k => MainCircuit -> Integer -> Constraints (Prime k)
genMain m order = constraints $ genMainCtx m order

genMainCtx :: KnownNat k => MainCircuit -> Integer -> Ctx k
genMainCtx m order =
        ctx'
    where
        ctx' = genStatement (SubDeclaration "main" [] (Just (main m))) ctxEmpty
        ctxEmpty = (ctxWithEnv Map.empty order) {
            callables = Map.union
                (Map.map (\(p, b) -> (False, p, b)) (templates m))
                (Map.map (\(p, b) -> (True , p, b)) (functions m))
        }
