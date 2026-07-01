{-# LANGUAGE BangPatterns #-}

import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as MV
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_)
import System.IO
import System.Directory (doesFileExist)
import System.Exit (exitWith, ExitCode(..))
import System.Environment (getArgs)
import Text.Printf (printf)

blockDevicePath :: FilePath
blockDevicePath = "/dev/md0"

pointerFilePath :: FilePath
pointerFilePath = "riemann_block_pointer.txt"

maxDeviceLimitBytes :: Integer
maxDeviceLimitBytes = 8100 * 1024 * 1024 * 1024 -- 8.1 Тб

-- | 1. Математическое ядро (чистый цикл на регистрах CPU)
evalZ :: Double -> Double
evalZ !t =
    let !nMax = floor (sqrt (t / (2.0 * pi)))
        !theta = (t / 2.0) * log (t / (2.0 * pi)) - (t / 2.0) - (pi / 8.0)
        go !idx !acc
            | idx > nMax = acc
            | otherwise =
                let !n = fromIntegral idx
                    !term = cos (theta - t * log n) / sqrt n
                in go (idx + 1) (acc + term)
    in 2.0 * go 1 0.0

-- | 2. Расчет и поиск нулей НА ЛЕТУ без аллокации промежуточных сеток значений
findZerosOnTheFly :: Double -> Double -> Int -> V.Vector Double
findZerosOnTheFly !t0 !deltaT !samples = V.create $ do
    mv <- MV.new samples
    let !step = deltaT / fromIntegral samples
        
        -- Проходим по всем сэмплам, вычисляя Z(t) и Z(t+step) на лету
        loop !i !count
            | i >= samples - 1 = return count
            | otherwise = do
                let !t1 = t0 + fromIntegral i * step
                    !t2 = t1 + step
                    !v1 = evalZ t1
                    !v2 = evalZ t2
                    !isZero = (v1 > 0 && v2 < 0) || (v1 < 0 && v2 > 0)
                    !tZero = t1 + (step / 2.0)
                if isZero
                    then do
                        MV.write mv count tZero
                        loop (i + 1) (count + 1)
                    else loop (i + 1) count
                    
    actualCount <- loop 0 0
    return $ MV.take actualCount mv

-- | 3. Низкоуровневый диспетчер под OS-потоки
processPipelineConcurrent :: Double -> Double -> IO (V.Vector Double)
processPipelineConcurrent !globalStart !globalEnd = do
    let numCores = 124
        !totalDelta = globalEnd - globalStart
        !chunkSize = totalDelta / fromIntegral numCores
        -- Увеличиваем плотность сэмплов на ядро для гарантированного отлова нулей
        !samplesPerCore = 250000 
        
    mvars <- forM [0 .. numCores - 1] $ \_ -> newEmptyMVar
    
    forM_ (zip [0 .. numCores - 1] mvars) $ \(coreIdx, mvar) -> forkIO $ do
        let !s = globalStart + fromIntegral coreIdx * chunkSize
            !e = s + chunkSize
            -- Никаких промежуточных массивов — чистый CPU-поток
            !zeros = findZerosOnTheFly s (e - s) samplesPerCore
        putMVar mvar zeros
        
    chunks <- mapM takeMVar mvars
    return $ V.concat chunks

getCurrentOffset :: IO Integer
getCurrentOffset = do
    exists <- doesFileExist pointerFilePath
    if exists
        then do
            content <- readFile pointerFilePath
            let !offset = read (head (lines content)) :: Integer
            return offset
        else return 0

main :: IO ()
main = do
    args <- getArgs
    case args of
        [blockNumStr, startStr, endStr] -> do
            let tStart = read startStr :: Double
                tEnd   = read endStr :: Double
            
            storableVector <- processPipelineConcurrent tStart tEnd
            
            let !totalCount  = V.length storableVector
                !sizeInBytes = fromIntegral (totalCount * 8) :: Integer
                !last10      = V.toList $ V.drop (max 0 (totalCount - 10)) storableVector

            currentOffset <- getCurrentOffset
            
            if currentOffset + sizeInBytes > maxDeviceLimitBytes
                then do
                    putStrLn "\n[!!!] КРИТИЧЕСКИЙ ОСТАНОВ: Достигнут лимит выделенных 8.1 Тб на RAID-0."
                    exitWith (ExitFailure 2)
                else return ()

            withFile blockDevicePath ReadWriteMode $ \devHandle -> do
                hSetBuffering devHandle NoBuffering
                hSeek devHandle AbsoluteSeek currentOffset
                V.unsafeWith storableVector $ \ptr ->
                    hPutBuf devHandle ptr (fromIntegral sizeInBytes)
                hFlush devHandle

            let !newOffset = currentOffset + sizeInBytes
            writeFile pointerFilePath (show newOffset ++ "\n")

            let csvPath = "riemann_chunks_summary.csv"
            withFile csvPath AppendMode $ \handle -> do
                hPutStrLn handle $ printf "%s;%s;%s;%d;%d" blockNumStr startStr endStr totalCount newOffset
                
            let remainingBytes = maxDeviceLimitBytes - newOffset
            putStrLn "========================================"
            printf "Блок №%s успешно записан НАПРЯМУЮ НА RAID-0.\n" blockNumStr
            printf "Интервал: от %.1f до %.1f\n" tStart tEnd
            printf "Текущее смещение на устройстве: %d байт (~%.2f Гб)\n" newOffset (fromIntegral newOffset / (1024**3) :: Double)
            printf "Осталось свободного места: %.2f Гб из 8.1 Тб\n" (fromIntegral remainingBytes / (1024**3) :: Double)
            printf "Найдено нулей в батче: %d\n" totalCount
            printf "Последние 10 найденных мнимых частей:\n"
            mapM_ (\z -> printf "  t = %.4f\n" z) last10
            putStrLn "========================================"
            
        _ -> putStrLn "Ошибка: Передайте аргументы: ./zeta_stress <номер_блока> <tStart> <tEnd>"
