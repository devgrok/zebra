{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Zebra.Foreign.Table (
    CTable(..)
  , tableOfForeign
  , foreignOfTable

  , deepCloneTable
  , neriticCloneTable
  , agileCloneTable
  , growTable

  , peekTable
  , pokeTable
  , peekColumn
  , pokeColumn
  ) where

import           Anemone.Foreign.Mempool (Mempool, alloc, calloc)

import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Trans.Either (EitherT, left, hoistEither, hoistMaybe)

import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text.Encoding as Text

import qualified X.Data.Vector as Boxed
import qualified X.Data.Vector.Storable as Storable

import           Foreign.Ptr (Ptr)

import           P

import           X.Data.Vector.Cons (Cons)
import qualified X.Data.Vector.Cons as Cons

import           Zebra.Foreign.Bindings
import           Zebra.Foreign.Util
import           Zebra.Table.Data
import qualified Zebra.Table.Encoding as Encoding
import qualified Zebra.Table.Striped as Striped
import qualified Zebra.X.Vector.Segment as Segment


newtype CTable =
  CTable {
      unCTable :: Ptr C'zebra_table
    }

tableOfForeign :: MonadIO m => CTable -> EitherT ForeignError m Striped.Table
tableOfForeign (CTable c_table) =
  peekTable c_table

foreignOfTable :: MonadIO m => Mempool -> Striped.Table -> m CTable
foreignOfTable pool table = do
  c_table <- liftIO $ alloc pool
  pokeTable pool c_table table
  pure $ CTable c_table

deepCloneTable :: MonadIO m => Mempool -> CTable -> EitherT ForeignError m CTable
deepCloneTable pool (CTable c_in_table) = do
  c_out_table <- liftIO $ calloc pool 1
  liftCError $ unsafe'c'zebra_deep_clone_table pool c_in_table c_out_table
  pure $ CTable c_out_table

neriticCloneTable :: MonadIO m => Mempool -> CTable -> EitherT ForeignError m CTable
neriticCloneTable pool (CTable c_in_table) = do
  c_out_table <- liftIO $ calloc pool 1
  liftCError $ unsafe'c'zebra_neritic_clone_table pool c_in_table c_out_table
  pure $ CTable c_out_table

agileCloneTable :: MonadIO m => Mempool -> CTable -> EitherT ForeignError m CTable
agileCloneTable pool (CTable c_in_table) = do
  c_out_table <- liftIO $ calloc pool 1
  liftCError $ unsafe'c'zebra_agile_clone_table pool c_in_table c_out_table
  pure $ CTable c_out_table

growTable :: MonadIO m => Mempool -> CTable -> Int -> EitherT ForeignError m ()
growTable pool (CTable c_table) grow_by = do
  liftCError $ unsafe'c'zebra_grow_table pool c_table (fromIntegral grow_by)

peekTable :: MonadIO m => Ptr C'zebra_table -> EitherT ForeignError m Striped.Table
peekTable c_table = do
  n_rows <- fromIntegral <$> peekIO (p'zebra_table'row_count c_table)
  n_cap <- fromIntegral <$> peekIO (p'zebra_table'row_capacity c_table)

  -- Make sure tests fail if the capacity is wrong
  when (n_cap < n_rows) $
    left ForeignTableNotEnoughCapacity

  let c_of = p'zebra_table'of c_table
  tag <- peekIO (p'zebra_table'tag c_table)
  case tag of
    C'ZEBRA_TABLE_BINARY ->
      Striped.Binary
        <$> peekDefault (p'zebra_table_variant'_binary'default_ c_of)
        <*> peekBinaryEncoding (p'zebra_table_variant'_binary'encoding c_of)
        <*> peekByteString n_rows (p'zebra_table_variant'_binary'bytes c_of)

    C'ZEBRA_TABLE_ARRAY ->
      Striped.Array
        <$> peekDefault (p'zebra_table_variant'_array'default_ c_of)
        <*> (peekColumn n_rows =<< peekIO (p'zebra_table_variant'_array'values c_of))

    C'ZEBRA_TABLE_MAP ->
      Striped.Map
        <$> peekDefault (p'zebra_table_variant'_map'default_ c_of)
        <*> (peekColumn n_rows =<< peekIO (p'zebra_table_variant'_map'keys c_of))
        <*> (peekColumn n_rows =<< peekIO (p'zebra_table_variant'_map'values c_of))

    _ ->
      left ForeignInvalidTableType

pokeTable :: MonadIO m => Mempool -> Ptr C'zebra_table -> Striped.Table -> m ()
pokeTable pool c_table table = do
  let
    c_tag =
      p'zebra_table'tag c_table

    c_of =
      p'zebra_table'of c_table

    n_rows =
      Striped.length table

  pokeIO (p'zebra_table'row_count c_table) $ fromIntegral n_rows
  pokeIO (p'zebra_table'row_capacity c_table) $ fromIntegral n_rows

  case table of
    Striped.Binary def encoding bytes -> do
      pokeIO c_tag C'ZEBRA_TABLE_BINARY
      pokeDefault (p'zebra_table_variant'_binary'default_ c_of) def
      pokeBinaryEncoding (p'zebra_table_variant'_binary'encoding c_of) encoding
      pokeByteString pool (p'zebra_table_variant'_binary'bytes c_of) bytes

    Striped.Array def values -> do
      pokeIO c_tag C'ZEBRA_TABLE_ARRAY
      pokeDefault (p'zebra_table_variant'_array'default_ c_of) def
      c_values <- liftIO $ calloc pool 1
      pokeIO (p'zebra_table_variant'_array'values c_of) c_values
      pokeColumn pool c_values values

    Striped.Map def keys values -> do
      pokeIO c_tag C'ZEBRA_TABLE_MAP
      pokeDefault (p'zebra_table_variant'_map'default_ c_of) def
      c_keys <- liftIO $ calloc pool 1
      c_values <- liftIO $ calloc pool 1
      pokeIO (p'zebra_table_variant'_map'keys c_of) c_keys
      pokeIO (p'zebra_table_variant'_map'values c_of) c_values
      pokeColumn pool c_keys keys
      pokeColumn pool c_values values

peekDefault :: MonadIO m => Ptr C'zebra_default -> EitherT ForeignError m Default
peekDefault ptr = do
  def <- peekIO ptr
  case def of
    C'ZEBRA_DEFAULT_DENY ->
      pure DenyDefault
    C'ZEBRA_DEFAULT_ALLOW ->
      pure AllowDefault
    _ ->
      left $ ForeignInvalidDefault (fromIntegral def)

pokeDefault :: MonadIO m => Ptr C'zebra_default -> Default-> m ()
pokeDefault ptr = \case
  DenyDefault ->
    pokeIO ptr C'ZEBRA_DEFAULT_DENY
  AllowDefault ->
    pokeIO ptr C'ZEBRA_DEFAULT_ALLOW

peekBinaryEncoding :: MonadIO m => Ptr C'zebra_binary_encoding -> EitherT ForeignError m Encoding.Binary
peekBinaryEncoding ptr = do
  encoding <- peekIO ptr
  case encoding of
    C'ZEBRA_BINARY_NONE ->
      pure Encoding.Binary
    C'ZEBRA_BINARY_UTF8 ->
      pure Encoding.Utf8
    _ ->
      left $ ForeignInvalidBinaryEncoding (fromIntegral encoding)

pokeIntEncoding :: MonadIO m => Ptr C'zebra_int_encoding -> Encoding.Int -> m ()
pokeIntEncoding ptr = \case
  Encoding.Int ->
    pokeIO ptr C'ZEBRA_INT_NONE
  Encoding.Date ->
    pokeIO ptr C'ZEBRA_INT_DATE
  Encoding.TimeSeconds ->
    pokeIO ptr C'ZEBRA_INT_TIME_SECONDS
  Encoding.TimeMilliseconds ->
    pokeIO ptr C'ZEBRA_INT_TIME_MILLISECONDS
  Encoding.TimeMicroseconds ->
    pokeIO ptr C'ZEBRA_INT_TIME_MICROSECONDS

peekIntEncoding :: MonadIO m => Ptr C'zebra_int_encoding -> EitherT ForeignError m Encoding.Int
peekIntEncoding ptr = do
  encoding <- peekIO ptr
  case encoding of
    C'ZEBRA_INT_NONE ->
      pure Encoding.Int
    C'ZEBRA_INT_DATE ->
      pure Encoding.Date
    C'ZEBRA_INT_TIME_SECONDS ->
      pure Encoding.TimeSeconds
    C'ZEBRA_INT_TIME_MILLISECONDS ->
      pure Encoding.TimeMilliseconds
    C'ZEBRA_INT_TIME_MICROSECONDS ->
      pure Encoding.TimeMicroseconds
    _ ->
      left $ ForeignInvalidIntEncoding (fromIntegral encoding)

pokeBinaryEncoding :: MonadIO m => Ptr C'zebra_binary_encoding -> Encoding.Binary -> m ()
pokeBinaryEncoding ptr = \case
  Encoding.Binary ->
    pokeIO ptr C'ZEBRA_BINARY_NONE
  Encoding.Utf8 ->
    pokeIO ptr C'ZEBRA_BINARY_UTF8
peekColumn :: MonadIO m => Int -> Ptr C'zebra_column -> EitherT ForeignError m Striped.Column
peekColumn n_rows c_column = do
  let column = p'zebra_column'of c_column
  tag <- peekIO (p'zebra_column'tag c_column)
  case tag of
    C'ZEBRA_COLUMN_UNIT ->
      Striped.Unit
        <$> pure n_rows

    C'ZEBRA_COLUMN_INT ->
      Striped.Int
        <$> peekDefault (p'zebra_column_variant'_int'default_ column)
        <*> peekIntEncoding (p'zebra_column_variant'_int'encoding column)
        <*> peekVector n_rows (p'zebra_column_variant'_int'values column)

    C'ZEBRA_COLUMN_DOUBLE ->
      Striped.Double
        <$> peekDefault (p'zebra_column_variant'_double'default_ column)
        <*> peekVector n_rows (p'zebra_column_variant'_double'values column)

    C'ZEBRA_COLUMN_ENUM ->
      Striped.Enum
        <$> peekDefault (p'zebra_column_variant'_enum'default_ column)
        <*> (tagsOfForeign <$> peekVector n_rows (p'zebra_column_variant'_enum'tags column))
        <*> peekNamedColumns mkVariant n_rows (p'zebra_column_variant'_enum'columns column)

    C'ZEBRA_COLUMN_STRUCT ->
      Striped.Struct
        <$> peekDefault (p'zebra_column_variant'_struct'default_ column)
        <*> peekNamedColumns mkField n_rows (p'zebra_column_variant'_struct'columns column)

    C'ZEBRA_COLUMN_NESTED ->
      Striped.Nested
        <$> peekOffsetsVector n_rows (p'zebra_column_variant'_nested'indices column)
        <*> peekTable (p'zebra_column_variant'_nested'table column)

    C'ZEBRA_COLUMN_REVERSED ->
      Striped.Reversed
        <$> (peekColumn n_rows =<< peekIO (p'zebra_column_variant'_reversed'column column))

    _ ->
      left ForeignInvalidColumnType

pokeColumn :: MonadIO m => Mempool -> Ptr C'zebra_column -> Striped.Column -> m ()
pokeColumn pool c_column column =
  let
    c_tag =
      p'zebra_column'tag c_column

    c_of =
      p'zebra_column'of c_column
  in
    case column of
      Striped.Unit _ ->
        pokeIO c_tag C'ZEBRA_COLUMN_UNIT

      Striped.Int def encoding xs -> do
        pokeIO c_tag C'ZEBRA_COLUMN_INT
        pokeDefault (p'zebra_column_variant'_int'default_ c_of) def
        pokeIntEncoding (p'zebra_column_variant'_int'encoding c_of) encoding
        pokeVector pool (p'zebra_column_variant'_int'values c_of) xs

      Striped.Double def xs -> do
        pokeIO c_tag C'ZEBRA_COLUMN_DOUBLE
        pokeDefault (p'zebra_column_variant'_double'default_ c_of) def
        pokeVector pool (p'zebra_column_variant'_double'values c_of) xs

      Striped.Enum def tags vs -> do
        pokeIO c_tag C'ZEBRA_COLUMN_ENUM
        pokeDefault (p'zebra_column_variant'_enum'default_ c_of) def
        pokeVector pool (p'zebra_column_variant'_enum'tags c_of) (foreignOfTags tags)
        pokeNamedColumns fromVariant pool (p'zebra_column_variant'_enum'columns c_of) vs

      Striped.Struct def fs -> do
        pokeIO c_tag C'ZEBRA_COLUMN_STRUCT
        pokeDefault (p'zebra_column_variant'_struct'default_ c_of) def
        pokeNamedColumns fromField pool (p'zebra_column_variant'_struct'columns c_of) fs

      Striped.Nested ns table -> do
        pokeIO c_tag C'ZEBRA_COLUMN_NESTED
        pokeOffsetsVector pool (p'zebra_column_variant'_nested'indices c_of) ns
        pokeTable pool (p'zebra_column_variant'_nested'table c_of) table

      Striped.Reversed inner -> do
        c_inner <- liftIO $ calloc pool 1
        pokeIO c_tag C'ZEBRA_COLUMN_REVERSED
        pokeIO (p'zebra_column_variant'_reversed'column c_of) c_inner
        pokeColumn pool c_inner inner

peekNamedColumns ::
     MonadIO m
  => (ByteString -> Striped.Column -> a)
  -> Int
  -> Ptr C'zebra_named_columns
  -> EitherT ForeignError m (Cons Boxed.Vector a)
peekNamedColumns f n_rows ptr = do
  n_columns <- peekIO $ p'zebra_named_columns'count ptr

  c_columns <- peekIO $ p'zebra_named_columns'columns ptr
  columns <- peekMany c_columns n_columns (peekColumn n_rows)

  name_lengths <- peekVector (fromIntegral n_columns) (p'zebra_named_columns'name_lengths ptr)
  name_lengths_sum <- peekIO $ p'zebra_named_columns'name_lengths_sum ptr
  name_bytes <- peekByteString (fromIntegral name_lengths_sum) (p'zebra_named_columns'name_bytes ptr)

  names <- firstT ForeignSegmentError . hoistEither $
    Segment.reify name_lengths name_bytes

  hoistMaybe ForeignFoundEmptyStructOrEnum . Cons.fromVector $ Boxed.zipWith f names columns

pokeNamedColumns ::
     MonadIO m
  => (a -> (ByteString, Striped.Column))
  -> Mempool
  -> Ptr C'zebra_named_columns
  -> Cons Boxed.Vector a
  -> m ()
pokeNamedColumns unpack pool c_column ncolumns = do
  let
    n_columns =
      Cons.length ncolumns

    (names, columns) =
      Boxed.unzip . Cons.toVector $ fmap unpack ncolumns

    (lens, total, bytes) =
      packedBytesOfVector names

  c_columns <- liftIO . calloc pool $ fromIntegral n_columns

  pokeIO (p'zebra_named_columns'count c_column) $ fromIntegral n_columns
  pokeIO (p'zebra_named_columns'columns c_column) c_columns
  pokeMany c_columns columns $ pokeColumn pool

  pokeIO (p'zebra_named_columns'name_lengths_sum c_column) total
  pokeVector pool (p'zebra_named_columns'name_lengths c_column) lens
  pokeByteString pool (p'zebra_named_columns'name_bytes c_column) bytes

mkField :: ByteString -> a -> Field a
mkField name x =
  Field (FieldName $ Text.decodeUtf8 name) x

fromField :: Field a -> (ByteString, a)
fromField (Field (FieldName name) x) =
  (Text.encodeUtf8 name, x)

mkVariant :: ByteString -> a -> Variant a
mkVariant name x =
  Variant (VariantName $ Text.decodeUtf8 name) x

fromVariant :: Variant a -> (ByteString, a)
fromVariant (Variant (VariantName name) x) =
  (Text.encodeUtf8 name, x)

peekOffsetsVector :: forall m. (MonadIO m) => Int -> Ptr (Ptr Int64) -> m (Storable.Vector Int64)
peekOffsetsVector n_rows p
 | n_rows == 0
 = return Storable.empty
 | otherwise
 = do ns <- peekVector (n_rows + 1) p
      return $ Storable.zipWith (-) (Storable.tail ns) ns

pokeOffsetsVector :: forall m. (MonadIO m) => Mempool -> Ptr (Ptr Int64) -> Storable.Vector Int64 -> m ()
pokeOffsetsVector pool p ns
 = pokeVector pool p (Storable.scanl (+) 0 ns)

-- Move this out of here later
-- For zebra_named_columns
packedBytesOfVector :: Boxed.Vector ByteString -> (Storable.Vector Int64, Int64, ByteString)
packedBytesOfVector strings
 = let lens  = Storable.convert $ fmap (fromIntegral . ByteString.length) strings
       bytes = ByteString.concat $ Boxed.toList strings
       total = fromIntegral $ ByteString.length bytes
   in (lens, total, bytes)
{-# INLINE packedBytesOfVector #-}
