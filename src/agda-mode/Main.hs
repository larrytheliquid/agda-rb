{-# LANGUAGE CPP #-}

-- | A program which either tries to add setup code for Agda's Emacs
-- mode to the users .emacs file, or provides information to Emacs
-- about where the Emacs mode is installed.

module Main (main) where

import Control.Exception
import Control.Monad
import Data.Char
import Data.List
import Data.Version
import Numeric
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
#if !(MIN_VERSION_base(4,2,0))
import qualified System.IO.UTF8 as UTF8
#endif
import System.Process

import Paths_Agda (getDataDir, version)

-- | The program.

main :: IO ()
main = do
  prog <- getProgName
  args <- getArgs
  case args of
    [arg] | arg == locateFlag -> printEmacsModeFile
          | arg == setupFlag  -> do
             dotEmacs <- findDotEmacs
             setupDotEmacs (Files { thisProgram = prog
                                  , dotEmacs    = dotEmacs
                                  })
    _  -> do inform usage
             exitFailure

-- Command line options.

setupFlag  = "setup"
locateFlag = "locate"

-- | Usage information.

usage :: String
usage = unlines
  [ "This program, which is part of Agda version " ++ ver ++ ", can be run"
  , "in two modes, depending on which option it is invoked with:"
  , ""
  , setupFlag
  , ""
  , "  The program tries to add setup code for Agda's Emacs mode to the"
  , "  current user's .emacs file. It is assumed that the .emacs file"
#if MIN_VERSION_base(4,2,0)
  , "  uses the character encoding specified by the locale."
#else
  , "  uses ASCII or some other character encoding which ASCII is"
  , "  compatible with (like Latin-1 or UTF-8)."
#endif
  , ""
  , locateFlag
  , ""
  , "  The path to the Emacs mode's main file is printed on standard"
  , "  output (using the UTF-8 character encoding and no trailing"
  , "  newline)."
  ]

-- | The current version of Agda.

ver :: String
ver = intercalate "." $ map show $
        versionBranch version

------------------------------------------------------------------------
-- Locating the Agda mode

-- | Prints out the path to the Agda mode's main file (using UTF-8 and
-- without any trailing newline).

printEmacsModeFile :: IO ()
printEmacsModeFile = do
  dataDir <- getDataDir
  let path = dataDir </> "emacs-mode" </> "agda2.el"
#if MIN_VERSION_base(4,2,0)
  hSetEncoding stdout utf8
  putStr path
#else
  UTF8.putStr path
#endif

------------------------------------------------------------------------
-- Setting up the .emacs file

data Files = Files { dotEmacs :: FilePath
                     -- ^ The .emacs file.
                   , thisProgram :: FilePath
                     -- ^ The name of the current program.
                   }

-- | Tries to set up the Agda mode in the given .emacs file.

setupDotEmacs :: Files -> IO ()
setupDotEmacs files = do
  informLn $ "The .emacs file used: " ++ dotEmacs files

  already <- alreadyInstalled files
  if already then
    informLn "It seems as if setup has already been performed."
   else do

    appendFile (dotEmacs files) (setupString files)
    inform $ unlines $
      [ "Setup done. Try to (re)start Emacs and open an Agda file."
      , "The following text was appended to the .emacs file:"
      ] ++ lines (setupString files)

-- | Tries to find the user's .emacs file by querying Emacs.

findDotEmacs :: IO FilePath
findDotEmacs = askEmacs "(insert (expand-file-name user-init-file))"

-- | Has the Agda mode already been set up?

alreadyInstalled :: Files -> IO Bool
alreadyInstalled files = do
  exists <- doesFileExist (dotEmacs files)
  if not exists then return False else
    withFile (dotEmacs files) ReadMode $ \h ->
      evaluate . (identifier files `isInfixOf`) =<< hGetContents h
      -- Uses evaluate to ensure that the file is not closed
      -- prematurely.

-- | If this string occurs in the .emacs file, then it is assumed that
-- setup has already been performed.

identifier :: Files -> String
identifier files =
  takeFileName (thisProgram files) ++ " " ++ locateFlag

-- | The string appended to the end of the .emacs file.

setupString :: Files -> String
setupString files = unlines
  [ ""
  , "(load-file (let ((coding-system-for-read 'utf-8))"
  , "                (shell-command-to-string \""
                        ++ identifier files ++ "\")))"
  ]

------------------------------------------------------------------------
-- Querying Emacs

-- | Evaluates the given Elisp command using Emacs. The output of the
-- command (whatever was written into the current buffer) is returned.
--
-- Note: The input is not checked. The input is assumed to come from a
-- trusted source.

askEmacs :: String -> IO String
askEmacs query = do
  tempDir <- getTemporaryDirectory
  bracket (openTempFile tempDir "askEmacs")
          (removeFile . fst) $ \(file, h) -> do
    hClose h
    exit <- rawSystem "emacs"
                      [ "--eval"
                      , "(with-temp-file " ++ escape file ++ " "
                                           ++ query ++ ")"
                      , "--kill"
                      ]
    unless (exit == ExitSuccess) $ do
      informLn "Unable to query Emacs."
      exitFailure
    withFile file ReadMode $ \h -> do
      result <- hGetContents h
      evaluate (length result)
      -- Uses evaluate to ensure that the file is not closed
      -- prematurely.
      return result

-- | Escapes the string so that Emacs can parse it as an Elisp string.

escape :: FilePath -> FilePath
escape s = "\"" ++ concatMap esc s ++ "\""
  where
  esc c | c `elem` ['\\', '"']   = '\\' : [c]
        | isAscii c && isPrint c = [c]
        | otherwise              = "\\x" ++ showHex (fromEnum c) "\\ "

------------------------------------------------------------------------
-- Helper functions

-- These functions inform the user about something by printing on
-- stderr.

inform   = hPutStr   stderr
informLn = hPutStrLn stderr
