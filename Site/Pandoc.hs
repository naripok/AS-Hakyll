{-# LANGUAGE OverloadedStrings #-}

module Site.Pandoc (pandocHtml5Compiler) where

import Hakyll.Web.Pandoc
import Text.Pandoc
import qualified Data.Set as S
import System.IO (hClose, hGetContents, hPutStr, hSetEncoding, localeEncoding)
import System.Process
import Control.Concurrent (forkIO)
import Control.Exception
import qualified Data.ByteString.Char8 as C (ByteString, pack)
import System.IO.Unsafe
import Crypto.Hash
import Text.Blaze.Html (preEscapedToHtml, (!))
import Text.Blaze.Html.Renderer.String (renderHtml)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

import System.Directory
import System.FilePath (takeDirectory)
import System.IO.Error (isDoesNotExistError)

pandocHtml5Compiler = pandocCompilerWith readerOpts writerOpts

cache :: String -> String -> FilePath -> String
cache code lang storePath = unsafePerformIO $ do
  let pathStem = (takeDirectory . takeDirectory $ storePath) ++ "/pygments/"

  _ <- createDirectoryIfMissing True pathStem

  let path = pathStem ++ "/" ++ newhash
      newhash = sha1 code

  readFile path `catch` handleExists path
  where cacheit path = do
          colored <- pygmentize lang code
          writeFile path colored
          return colored
        sha1 :: String -> String
        sha1 = show . sha1hash . C.pack
          where sha1hash = hash :: C.ByteString -> Digest SHA1
        handleExists :: FilePath -> IOError -> IO String
        handleExists path e
          | isDoesNotExistError e = cacheit path
          | otherwise = throwIO e

pygments :: FilePath -> Block -> Block
pygments storePath (CodeBlock (_, classes, keyvals) contents) =
  let lang = case lookup "lang" keyvals of
               Just language -> language
               Nothing -> if not . null $ classes
                            then head classes
                            else "text"
      text = lookup "text" keyvals
      colored = renderHtml $ H.div ! A.class_ (H.toValue $ "code-container " ++ lang) $ do
                  preEscapedToHtml $ cache contents lang storePath
      caption = maybe "" (renderHtml . H.figcaption . H.span . preEscapedToHtml) text
      composed = renderHtml $ H.figure ! A.class_ "code" $ do
                   preEscapedToHtml $ colored ++ caption
  in RawBlock "html" composed
pygments _ x = x

pygmentize :: String -> String -> IO String
pygmentize lang contents = do
  let process = (shell ("pygmentize -f html -l " ++ lang ++ " -P encoding=utf-8")) {
                  std_in = CreatePipe, std_out = CreatePipe, close_fds = True}
      writer h input = do
        hSetEncoding h localeEncoding
        hPutStr h input
      reader h = do
        hSetEncoding h localeEncoding
        hGetContents h

  (Just stdin, Just stdout, _, _) <- createProcess process

  _ <- forkIO $ do
    writer stdin contents
    hClose stdin

  reader stdout

readerOpts :: ReaderOptions
readerOpts =
  let extensions = S.fromList [
        Ext_tex_math_dollars,
        Ext_abbreviations
        ]
  in def {
    readerSmart = True,
    readerExtensions = S.union extensions (writerExtensions def)
    }

writerOpts :: WriterOptions
writerOpts = def {
  writerHTMLMathMethod = MathJax "",
  writerHighlight = False,
  writerHtml5 = True }