{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE Rank2Types                 #-}
module Codec.Compression.Zlib.Monad(
         DeflateM
       , runDeflateM
       , ZlibDecoder(..)
       , raise
       , DecompressionError(..)
         -- * Getting data from the input stream.
       , nextBit
       , nextBits
       , nextByte
       , nextWord16
       , nextWord32
       , nextBlock
       , nextCode
         -- * Aligning
       , advanceToByte
         -- * Emitting data into the output window
       , emitByte
       , emitBlock
       , emitPastChunk
         -- * Getting and publishing output
       , finalAdler
       , moveWindow
       , finalize
       )
 where

import           Codec.Compression.Zlib.Adler32(AdlerState, initialAdlerState,
                                                advanceAdler, finalizeAdler)
import           Codec.Compression.Zlib.HuffmanTree(HuffmanTree, advanceTree,
                                                    AdvanceResult(..))
import           Codec.Compression.Zlib.OutputWindow(OutputWindow, emptyWindow,
                                                     emitExcess, addByte,
                                                     addChunk, addOldChunk,
                                                     finalizeWindow)
import           Control.Exception(Exception)
import           Control.Monad(Monad)
import           Data.Bits(Bits(..))
import qualified Data.ByteString      as S
import qualified Data.ByteString.Lazy as L
import           Data.Int(Int64)
import           Data.Typeable(Typeable)
import           Data.Word(Word32, Word16, Word8)
import           Prelude()
import           Prelude.Compat

data DecompressionState = DecompressionState {
       dcsNextBitNo     :: !Int
     , dcsCurByte       :: !Word8
     , dcsAdler32       :: !AdlerState
     , dcsInput         :: !S.ByteString
     , dcsOutput        :: !OutputWindow
     }

instance Show DecompressionState where
  show dcs = "DecompressionState<nextBit=" ++ show (dcsNextBitNo dcs) ++ "," ++
             "curByte=" ++ show (dcsCurByte dcs) ++ ",inputLen=" ++
             show (S.length (dcsInput dcs)) ++ ">"

-- -----------------------------------------------------------------------------

data DecompressionError = HuffmanTreeError   String
                        | FormatError        String
                        | DecompressionError String
                        | HeaderError        String
                        | ChecksumError      String
  deriving (Typeable, Eq)

instance Show DecompressionError where
  show x =
    case x of
      HuffmanTreeError   s -> "Huffman tree manipulation error: " ++ s
      FormatError        s -> "Block format error: " ++ s
      DecompressionError s -> "Decompression error: " ++ s
      HeaderError        s -> "Header error: " ++ s
      ChecksumError      s -> "Checksum error: " ++ s

instance Exception DecompressionError

-- -----------------------------------------------------------------------------

newtype DeflateM a = DeflateM {
    unDeflateM :: DecompressionState -> (DecompressionState -> a -> ZlibDecoder) -> ZlibDecoder
  }

instance Applicative DeflateM where
  pure  x = DeflateM (\ s k -> k s x)

  f <*> x = DeflateM $ \ s1 k ->
     unDeflateM f s1 $ \ s2 g ->
     unDeflateM x s2 $ \ s3 y -> k s3 (g y)

  m *> n = DeflateM $ \ s1 k ->
    unDeflateM m s1 $ \ s2 _ -> unDeflateM n s2 k

  {-# INLINE pure #-}
  {-# INLINE (<*>) #-}
  {-# INLINE (*>) #-}


instance Functor DeflateM where
  fmap f m = DeflateM (\s k -> unDeflateM m s (\s' a -> k s' (f a)))
  {-# INLINE fmap #-}

instance Monad DeflateM where
  {-# INLINE return #-}
  return = pure

  {-# INLINE (>>=) #-}
  m >>= f = DeflateM $ \ s1 k ->
     unDeflateM m s1 $ \ s2 a -> unDeflateM (f a) s2 k

  (>>) = (*>)
  {-# INLINE (>>) #-}

get :: DeflateM DecompressionState
get = DeflateM (\ s k -> k s s)
{-# INLINE get #-}

set :: DecompressionState -> DeflateM ()
set !s = DeflateM (\ _ k -> k s ())
{-# INLINE set #-}

raise :: DecompressionError -> DeflateM a
raise e = DeflateM (\ _ _ -> DecompError e)
{-# INLINE raise #-}

initialState :: DecompressionState
initialState = DecompressionState {
    dcsNextBitNo = 8
  , dcsCurByte   = 0
  , dcsAdler32   = initialAdlerState
  , dcsInput     = S.empty
  , dcsOutput    = emptyWindow
  }

-- -----------------------------------------------------------------------------

data ZlibDecoder = NeedMore (S.ByteString -> ZlibDecoder)
                 | Chunk S.ByteString ZlibDecoder
                 | Done
                 | DecompError DecompressionError

runDeflateM :: DeflateM () -> ZlibDecoder
runDeflateM m = unDeflateM m initialState (\ _ _ -> Done)
{-# INLINE runDeflateM #-}

-- -----------------------------------------------------------------------------

getNextChunk :: DeflateM ()
getNextChunk = DeflateM $ \ st k -> NeedMore (loadChunk st k)
 where
  loadChunk st k bstr =
    case S.uncons bstr of
      Nothing -> NeedMore (loadChunk st k)
      Just (nextb, rest) ->
         k st { dcsNextBitNo = 0, dcsCurByte = nextb, dcsInput = rest } ()

nextBit :: DeflateM Bool
nextBit =
  do dcs <- get
     let !nextBitNo = dcsNextBitNo dcs
     case compare nextBitNo 8 of
       GT -> raise (DecompressionError "Weird bit state")
       EQ -> case S.uncons (dcsInput dcs) of
               Nothing -> getNextChunk >> nextBit
               Just (nextb, rest) ->
                 do set dcs{ dcsNextBitNo = 0
                           , dcsCurByte   = nextb
                           , dcsInput     = rest }
                    nextBit

       LT -> do let !v = dcsCurByte dcs `testBit` nextBitNo
                set $ dcs{ dcsNextBitNo = nextBitNo + 1 }
                return v

nextBits :: (Show a, Num a, Bits a) => Int -> DeflateM a
nextBits x | x < 1     = error "nextBits called with x < 1"
           | otherwise = go 0 0
 where
  go :: (Show a, Num a, Bits a) => Int -> a -> DeflateM a
  go shiftNum acc
    | shiftNum == x = return acc
    | otherwise     = do cur <- toNum `fmap` nextBit
                         go (shiftNum + 1) (acc .|. (cur `shiftL` shiftNum))
  --
  toNum False = 0
  toNum True  = 1

nextByte :: DeflateM Word8
nextByte =
  do dcs <- get
     if | dcsNextBitNo dcs == 0 -> do set dcs{ dcsNextBitNo = 8 }
                                      return (dcsCurByte dcs)
        | dcsNextBitNo dcs /= 8 -> nextBits 8 -- we're not aligned. sigh.
        | otherwise             -> case S.uncons (dcsInput dcs) of
                                     Nothing -> getNextChunk >> nextByte
                                     Just (nextb, rest) ->
                                       do set dcs{ dcsNextBitNo = 8,
                                                   dcsCurByte   = nextb,
                                                   dcsInput     = rest }
                                          return nextb

nextWord16 :: DeflateM Word16
nextWord16 =
  do low  <- fromIntegral `fmap` nextByte
     high <- fromIntegral `fmap` nextByte
     return ((high `shiftL` 8) .|. low)

nextWord32 :: DeflateM Word32
nextWord32 =
  do a <- fromIntegral `fmap` nextByte
     b <- fromIntegral `fmap` nextByte
     c <- fromIntegral `fmap` nextByte
     d <- fromIntegral `fmap` nextByte
     return ((a `shiftL` 24) .|. (b `shiftL` 16) .|. (c `shiftL` 8) .|. d)

nextBlock :: Integral a => a -> DeflateM L.ByteString
nextBlock amt =
  do dcs <- get
     if | dcsNextBitNo dcs == 0 ->
            do let startByte = dcsCurByte dcs
               set dcs{ dcsNextBitNo = 8 }
               rest <- nextBlock (amt - 1)
               return (L.cons startByte rest)
        | dcsNextBitNo dcs == 8 ->
            getBlock (fromIntegral amt) (dcsInput dcs)
        | otherwise             ->
            fail "Can't get a block on a non-byte boundary."
 where
  getBlock len bstr
    | len < S.length bstr = do let (mine, rest) = S.splitAt len bstr
                               dcs <- get
                               set dcs{ dcsNextBitNo = 8, dcsInput = rest }
                               return (L.fromStrict mine)
    | S.null bstr         = do getNextChunk
                               dcs <- get
                               let byte1 = dcsCurByte dcs
                               rest <- getBlock (len - 1) (dcsInput dcs)
                               return (L.cons byte1 rest)
    | otherwise           = do rest <- getBlock (len - S.length bstr) S.empty
                               return (L.fromStrict bstr `L.append` rest)

nextCode :: Show a => HuffmanTree a -> DeflateM a
nextCode tree =
  do b <- nextBit
     case advanceTree b tree of
       AdvanceError str -> raise (HuffmanTreeError str)
       NewTree tree'    -> nextCode tree'
       Result x         -> return x
{-# INLINE nextCode #-}

advanceToByte :: DeflateM ()
advanceToByte =
  do dcs <- get
     set dcs{ dcsNextBitNo = 8 }

emitByte :: Word8 -> DeflateM ()
emitByte b =
  do dcs <- get
     set dcs{ dcsOutput  = dcsOutput dcs `addByte` b
            , dcsAdler32 = advanceAdler (dcsAdler32 dcs) b }
{-# INLINE emitByte #-}

emitBlock :: L.ByteString -> DeflateM ()
emitBlock b =
  do dcs <- get
     set dcs { dcsOutput  = dcsOutput dcs `addChunk` b
             , dcsAdler32 = L.foldl advanceAdler (dcsAdler32 dcs) b }

emitPastChunk :: Int -> Int64 -> DeflateM ()
emitPastChunk dist len =
  do dcs <- get
     let (output', newChunk) = addOldChunk (dcsOutput dcs) dist len
     set dcs { dcsOutput = output'
             , dcsAdler32 = L.foldl advanceAdler (dcsAdler32 dcs) newChunk }
{-# INLINE emitPastChunk #-}

finalAdler :: DeflateM Word32
finalAdler = (finalizeAdler . dcsAdler32) `fmap` get

moveWindow :: DeflateM ()
moveWindow =
  do dcs <- get
     case emitExcess (dcsOutput dcs) of
       Nothing ->
         return ()
       Just (builtChunks, output') ->
         do set dcs{ dcsOutput = output' }
            publishLazy builtChunks

finalize :: DeflateM ()
finalize =
  do dcs <- get
     publishLazy (finalizeWindow (dcsOutput dcs))

{-# INLINE publishLazy #-}
publishLazy :: L.ByteString -> DeflateM ()
publishLazy lbstr = DeflateM (\ st k -> go st k (L.toChunks lbstr))
 where
  go st k []       = k st ()
  go st k (c:rest) = Chunk c (go st k rest)
