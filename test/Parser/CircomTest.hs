module Parser.CircomTest where
import           BenchUtils
import           Control.Monad (unless)
import           Data.Either   (fromLeft, isRight)
import           AST.Circom
import           Parser.Circom.Lexer (tokenize)
import           Parser.Circom        (parseFile, loadFilesRecursively, loadMain)
import           Parser.Circom.Parser (parseCircomExpr, parseCircomStatement)
import           Utils

circomParserTests :: BenchTest
circomParserTests = benchTestGroup "Circom tests"
    [ testLex "test/Code/Circom/inout.circom"
    , testExprParse "5" Nothing
    , testExprParse "x" $ Just $ LValue $ Ident "x"
    , testExprParse "x + 5" Nothing
    , testExprParse "in[j][k] * 2**k" Nothing --  https://github.com/iden3/circomlib/blob/master/circuits/binsum.circom#L77
    , testExprParse "2**k * in[j][k]" $ Just $ BinExpr Mul (BinExpr Pow (NumLit 2) (LValue (Ident "k"))) (LValue (Index (Index (Ident "in") (LValue (Ident "j"))) (LValue (Ident "k"))))
    , testExprParse "2**(k * in[j][k])" Nothing
    , testExprParse "out[k] * (out[k] - 1)" Nothing --  https://github.com/iden3/circomlib/blob/master/circuits/binsum.circom#L85
    , testExprParse "[x, y, z + 5]" $ Just $ ArrayLit [LValue $ Ident "x", LValue $ Ident "y", BinExpr Add (LValue $ Ident "z") (NumLit 5)]
    , testExprParse "x + -x" $ Just $ BinExpr Add (LValue $ Ident "x") (UnExpr UnNeg (LValue $ Ident "x"))
    , testStatementParse "x + -x;" $ Just $ Ignore $ BinExpr Add (LValue $ Ident "x") (UnExpr UnNeg (LValue $ Ident "x"))
    , testStatementParse "signal input in[ops][n];" Nothing
    , testStatementParse "var nout = nbits((2**n -1)*ops);" Nothing
    , testStatementParse "for (var i = 0; i < n; i += 1) { j += i; }" Nothing
    , testStatementParse "for(k=0;k<n;k++){for(j=0;j<ops;j++){lin+=in[j][k]*2**k;}}" Nothing -- https://github.com/iden3/circomlib/blob/master/circuits/binsum.circom#L75
    , testParse "test/Code/Circom/binsum.circom"
    , testParse "test/Code/Circom/eddsamimcsponge.circom"
    , testParse "test/Code/Circom/poseidon.circom"
    , testParse "test/Code/Circom/gates.circom"
    , testParse "test/Code/Circom/mux4.circom"
    , testParse "test/Code/Circom/pedersen.circom"
    , testParse "test/Code/Circom/compconstant.circom"
    , testParse "test/Code/Circom/bitify.circom"
    , testParse "test/Code/Circom/aliascheck.circom"
    , testParse "test/Code/Circom/comparators.circom"
    , testLoad "test/Code/Circom/bitify.circom"
    , testLoadMain "test/Code/Circom/bitify-main.circom"
    , testLoadMain "test/Code/Circom/bitify4.circom"
    ]

testLex :: String -> BenchTest
testLex path = benchTestCase ("lex " ++ path) $ do
  string <- readFile path
  let tokens = tokenize string
  print tokens

testExprParse :: String -> Maybe Expr -> BenchTest
testExprParse expr expected = benchTestCase ("parse expr `" ++ expr ++ "`") $ do
  let lexed = tokenize expr
  let parsed = parseCircomExpr lexed
  case expected of
    Nothing -> pure ()
    Just r -> if r == parsed
        then pure ()
        else error $ "Error: expected " ++ show r ++ " but got " ++ show parsed
  print parsed

testStatementParse :: String -> Maybe Statement -> BenchTest
testStatementParse stat expected = benchTestCase ("parse statement `" ++ stat ++ "`") $ do
  let lexed = tokenize stat
  let parsed = parseCircomStatement lexed
  case expected of
    Nothing -> pure ()
    Just r -> if r == parsed
        then pure ()
        else error $ "Error: expected " ++ show r ++ " but got " ++ show parsed
  print parsed

testParse :: String -> BenchTest
testParse path = benchTestCase ("parse " ++ path) $ do
  ast <- parseFile path
  print $ "items in " ++ path ++ ": " ++ show (length ast)

testLoad :: String -> BenchTest
testLoad path = benchTestCase ("load " ++ path) $ do
  pgm <- loadFilesRecursively path
  print $ "files from " ++ path ++ ": " ++ show (length pgm)

testLoadMain :: String -> BenchTest
testLoadMain path = benchTestCase ("load " ++ path) $ do
  pgm <- loadMain path
  print $ "main expression in " ++ path ++ ": " ++ show (main pgm)
