-- |
-- Copyright   : (c) 2024 Tamarin Prover Team
-- License     : GPL v3 (see LICENSE)
--
-- Portability : GHC only
--
-- Disk caching utilities for precomputation results.
module Theory.Tools.Cache
  ( CacheConfig(..)
  , defaultCacheConfig
  , getCacheDir
  , clearCache
  , clearOldCaches
  , withCache
  ) where

import qualified Data.Binary            as B
import qualified Data.ByteString.Lazy   as BL
import           Control.Exception      (SomeException, try)
import           Control.Monad          (when, forM_)
import           System.Directory       (createDirectoryIfMissing,
                                         doesFileExist, renameFile,
                                         getXdgDirectory, XdgDirectory(..),
                                         removeDirectoryRecursive,
                                         doesDirectoryExist,
                                         listDirectory)
import           System.FilePath        ((</>))
import           System.IO              (openBinaryTempFile, hClose)
import           System.IO.Unsafe       (unsafePerformIO)
import           Utils.Misc             (stringSHA256)

-- | Configuration for disk caching behavior.
data CacheConfig = CacheConfig
  { ccEnabled        :: Bool     -- ^ Whether caching is enabled
  , ccTamarinVersion :: String   -- ^ Tamarin prover version string
  , ccMaudeVersion   :: String   -- ^ Maude version string
  , ccGitHash        :: String   -- ^ Git commit hash (short)
  } deriving (Show)

-- | Default: caching enabled, versions/hash empty (must be filled in).
defaultCacheConfig :: CacheConfig
defaultCacheConfig = CacheConfig True "" "" ""

-- | Get the base cache directory: $XDG_CACHE_HOME/tamarin-prover/
getCacheDir :: IO FilePath
getCacheDir = getXdgDirectory XdgCache "tamarin-prover"

-- | The version directory name for a given config.
-- Format: Tamarin_<version>-<shortGitHash>_Maude_<maudeVersion>
-- e.g. "Tamarin_1.9.0-abc1234_Maude_3.3.1"
versionDirName :: CacheConfig -> String
versionDirName cfg =
  "Tamarin_" ++ ccTamarinVersion cfg ++ "-" ++ take 7 (ccGitHash cfg)
  ++ "_Maude_" ++ strip (ccMaudeVersion cfg)
  where
    strip = reverse . dropWhile (\c -> c == '\n' || c == ' ') . reverse

-- | Remove the entire cache directory (all versions).
clearCache :: IO ()
clearCache = do
  dir <- getCacheDir
  exists <- doesDirectoryExist dir
  when exists $ removeDirectoryRecursive dir

-- | Remove all version subdirectories except the current one.
clearOldCaches :: CacheConfig -> IO ()
clearOldCaches cfg = do
  base <- getCacheDir
  exists <- doesDirectoryExist base
  when exists $ do
    let current = versionDirName cfg
    entries <- listDirectory base
    forM_ entries $ \entry -> do
      let fullPath = base </> entry
      isDir <- doesDirectoryExist fullPath
      when (isDir && entry /= current) $ do
        putStrLn $ "Removing old cache: " ++ entry
        removeDirectoryRecursive fullPath
    putStrLn $ "Kept current cache: " ++ current

-- | Cache a pure computation to disk. The lazy value @val@ is only forced on
-- a cache miss, so callers pay no evaluation cost on a hit.
--
-- Uses 'unsafePerformIO' for disk I/O, which is safe here because the
-- function is a pure memoization: identical inputs always produce identical
-- outputs. Writes use atomic rename to be safe under concurrent access.
withCache :: B.Binary a => CacheConfig -> String -> String -> a -> a
withCache cfg subdir keyStr val
  | not (ccEnabled cfg) = val
  | otherwise = unsafePerformIO $ do
      let dir  = versionDirName cfg </> subdir
      path <- cacheFilePath dir keyStr
      cached <- readCacheFile path
      case cached of
        Just result -> pure result
        Nothing     -> do
          _ <- try (writeCacheFile dir path val) :: IO (Either SomeException ())
          pure val

-- Internal helpers (not exported)

cacheFilePath :: String -> String -> IO FilePath
cacheFilePath dir keyStr = do
  base <- getCacheDir
  pure $ base </> dir </> stringSHA256 keyStr ++ ".bin"

readCacheFile :: B.Binary a => FilePath -> IO (Maybe a)
readCacheFile path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      result <- try (B.decodeFile path) :: B.Binary a => IO (Either SomeException a)
      case result of
        Left  _   -> pure Nothing   -- corrupt cache -> recompute
        Right val -> pure (Just val)

writeCacheFile :: B.Binary a => String -> FilePath -> a -> IO ()
writeCacheFile dir path val = do
  base <- getCacheDir
  let fullDir = base </> dir
  createDirectoryIfMissing True fullDir
  (tmpFile, tmpHandle) <- openBinaryTempFile fullDir "cache.tmp"
  BL.hPut tmpHandle (B.encode val)
  hClose tmpHandle
  renameFile tmpFile path
