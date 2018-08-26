module ConfCrypt.Commands (
    -- | Command class
    Command,
    evaluate,

    -- | Supported Commands
    ReadConfCrypt(..),
    AddConfCrypt(..),
    EditConfCrypt(..),
    DeleteConfCrypt(..),
    ValidateConfCrypt(..),
    EncryptWholeConfCrypt(..),

    -- | Exported for testing
    genNewFileState,
    writeFullContentsToBuffer,

    FileAction(..)
    ) where

import ConfCrypt.Types
import ConfCrypt.Encryption (encryptValue, decryptValue)

import Control.Arrow (second)
import Control.Monad.Trans (lift)
import Control.Monad.Reader (ask)
import Control.Monad.Except (throwError, MonadError)
import Control.Monad.Writer (tell, MonadWriter)
import Crypto.Random (MonadRandom)
import Data.Foldable (foldrM, traverse_)
import Data.List (sortOn)
import GHC.Generics (Generic)
import qualified Crypto.PubKey.RSA.Types as RSA
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map as M

import Debug.Trace

data FileAction
    = Add
    | Edit
    | Remove

class Monad m => Command a m where
    evaluate :: a -> m ()

data ReadConfCrypt = ReadConfCrypt
instance Monad m => Command ReadConfCrypt (ConfCryptM m RSA.PrivateKey) where
    evaluate _ = do
        (ccFile, pk) <- ask
        let params = parameters ccFile
        transformed <- mapM (\p -> decryptedParam  p $ decryptValue pk (paramValue p)) params
        let transformedLines = [(p, Edit)| p <- transformed]
        newcontents <- genNewFileState (fileContents ccFile) transformedLines
        writeFullContentsToBuffer newcontents
        where
            decryptedParam param (Left e) = throwError e
            decryptedParam param (Right v) = pure . ParameterLine $ ParamLine {pName = paramName param, pValue = v}

data AddConfCrypt = AddConfCrypt {aName :: T.Text, aValue :: T.Text, aType :: SchemaType}
    deriving (Eq, Read, Show, Generic)
instance (Monad m, MonadRandom m) => Command AddConfCrypt (ConfCryptM m RSA.PublicKey) where
    evaluate AddConfCrypt {aName, aValue, aType} =  do
        (ccFile, pubKey) <- ask
        mEncryptedValue <- lift . lift . lift $ encryptValue pubKey aValue
        encryptedValue <- either throwError pure mEncryptedValue
        let contents = fileContents ccFile
            instructions = [(SchemaLine sl, Add), (ParameterLine (pl {pValue = wrapEncryptedValue encryptedValue}), Add)]
        newcontents <- genNewFileState contents instructions
        writeFullContentsToBuffer newcontents
        where
            (pl, Just sl) = parameterToLines $ Parameter {paramName = aName, paramValue = aValue, paramType = Just aType}


data EditConfCrypt = EditConfCrypt {eName:: T.Text, eValue :: T.Text, eType :: SchemaType}
    deriving (Eq, Read, Show, Generic)
instance (Monad m, MonadRandom m) => Command EditConfCrypt (ConfCryptM m RSA.PublicKey) where
    evaluate = undefined


data DeleteConfCrypt = DeleteConfCrypt {dName:: T.Text}
    deriving (Eq, Read, Show, Generic)
instance (Monad m, MonadRandom m) => Command DeleteConfCrypt (ConfCryptM m ()) where
    evaluate = undefined

data ValidateConfCrypt = ValidateConfCrypt
instance (Monad m) => Command ValidateConfCrypt (ConfCryptM m RSA.PrivateKey) where
    evaluate = undefined

data EncryptWholeConfCrypt = EncryptWholeConfCrypt
instance (Monad m, MonadRandom m) => Command EncryptWholeConfCrypt (ConfCryptM m RSA.PublicKey) where
    evaluate = undefined

-- | Given a known file state and some edits, apply the edits and produce the new file contents
genNewFileState :: (Monad m, MonadError ConfCryptError m) =>
    M.Map ConfCryptElement LineNumber -- ^ initial file state
    -> [(ConfCryptElement, FileAction)] -- ^ edits
    -> m (M.Map ConfCryptElement LineNumber) -- ^ new file, with edits applied in-place
genNewFileState fileContents [] = pure fileContents
genNewFileState fileContents ((CommentLine _, _):rest) = genNewFileState fileContents rest
genNewFileState fileContents ((line, action):rest) =
    case M.toList (mLine line) of
        [] ->
            case action of
                Add -> let
                    nums =  M.elems fileContents
                    LineNumber highestLineNum = if null nums then LineNumber 1 else maximum nums
                    fc' = M.insert line (LineNumber $ highestLineNum + 1) fileContents
                    in genNewFileState fc' rest
                _ -> throwError $ MissingLine (T.pack $ show line)
        [(key, lineNum@(LineNumber lnValue))] ->
            case action of
                Remove -> let
                    fc' = M.delete key fileContents
                    fc'' = (\(LineNumber l) -> if l > lnValue then LineNumber (l - 1) else LineNumber l) <$> fc'
                    in genNewFileState fc'' rest
                Edit -> let
                    fc' = M.delete key fileContents
                    fc'' = M.insert (trace ("Ostensibly Adding: " <> show line) line) lineNum fc'
                    in genNewFileState fc'' rest
                _ -> throwError $ WrongFileAction ((<> " should be an Add"). T.pack $ show line)
        _ -> error "viloates map key uniqueness"

    where
        mLine l = M.filterWithKey (\k _ -> k == l) fileContents

writeFullContentsToBuffer :: (Monad m, MonadWriter [T.Text] m) =>
    M.Map ConfCryptElement LineNumber
    -> m ()
writeFullContentsToBuffer contents =
    traverse_ (tell . singleton . toDisplayLine) sortedLines
    where
        sortedLines = fmap fst . sortOn snd $ M.toList contents
        singleton x = [x]

toDisplayLine ::
    ConfCryptElement
    -> T.Text
toDisplayLine (CommentLine comment) = "# " <> comment
toDisplayLine (SchemaLine (Schema name tpe)) = name <> " : " <> typeToOutputString tpe
toDisplayLine (ParameterLine (ParamLine name val)) = name <> " = " <> val


-- | Because the encrypted results are stored as UTF8 text, its possible for an encrypted value
-- to embed end-of-line (eol) characters into the output value. This means rather than relying on eol
-- as our delimeter we need to explicitly wrap encrypted values in something very unlikely to occur w/in
-- an encrypted value.
wrapEncryptedValue ::
    T.Text
    -> T.Text
wrapEncryptedValue v = "BEGIN"<>v<>"END"
