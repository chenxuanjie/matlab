%% 舵偏补偿扫描分析脚本
% 功能说明：
% 1. 自动读取 rudder_angle 下的 u_trim_scan-*.csv。
% 2. 重点提取 row_type = point_summary 的扫描点结果。
% 3. 建立 PWM 差值 -> 平均角速度 的关系，并绘制多种图形。
% 4. 通过线性插值或拟合方法，估计“角速度为 0”时的直行补偿量。
%
% 重要说明：
% 1. 默认优先使用线性插值；当扫描点没有跨过 0 deg/s 时，可回退到最近点，
%    或将 primaryZeroSolveMethod 改为 poly1 / poly2 做拟合求根。
% 2. 本脚本默认先扫描 experiment_tests；如果没有可用 CSV，会回退到
%    origin_experiment_test。

clc;
clear;
close all;

scriptDir = fileparts(mfilename('fullpath'));

%% ======================== 输入配置区（可直接修改） ========================

% 输入模式：
% 'auto'   -> 自动选择 1 个 CSV；先找 experiment_tests，再回退到 origin_experiment_test
% 'folder' -> 在指定文件夹中自动选择 1 个 CSV
% 'single' -> 读取指定单个 CSV 文件；当 inputPath 为空时，行为等同于 auto
inputMode = 'auto';

% 当 inputMode = 'folder' 时，inputPath 填文件夹路径；
% 当 inputMode = 'single' 时，inputPath 填单个文件路径。
inputPath = '';

% CSV 文件匹配模式
filePattern = 'u_trim_scan-*.csv';

% 文件夹模式下是否递归搜索子文件夹
includeSubfolders = true;

% 自动模式或文件夹模式下，如何从匹配到的文件中选 1 个
% 'latest' -> 按修改时间选择最新文件
% 'name'   -> 按文件名排序后取最后一个，适合 u_trim_scan-*.csv 这类带时间戳文件名
autoPickRule = 'name';

%% ======================== 分析参数区（可直接修改） ========================

% 每次试验零点求解的首选方法：
% 'linear' -> 优先使用相邻点线性插值
% 'poly1'  -> 一次拟合
% 'poly2'  -> 二次拟合
% 'nearest'-> 直接取最接近 0 deg/s 的扫描点
primaryZeroSolveMethod = 'linear';

% 当首选方法失败时使用的回退方法
fallbackZeroSolveMethod = 'nearest';

% 总体统计图中的拟合阶数
% 1 = 直线拟合
% 2 = 二次拟合
aggregateFitDegree = 1;

% 是否显示各类图形
showControllerOutputFigure = true;
showYawRateTimeFigure = true;
showPerRunFigure = true;
showOverlayFigure = false;
showAggregateFigure = true;
showSummaryFigure = false;

% 是否把汇总结果保存为 CSV
saveSummaryCsv = false;

% 是否导出 PNG 图片
saveFigures = false;

% 结果输出目录（相对于当前脚本目录）
outputRoot = 'results';

%% ======================== 绘图样式区 ========================

lineWidth = 1.2;
fitLineWidth = 1.5;
markerSize = 6;
trimMarkerSize = 60;
aggregateMarkerSize = 26;
referenceLineColor = [0.35, 0.35, 0.35];
fitLineColor = [0.82, 0.10, 0.10];
aggregateColor = [0.12, 0.40, 0.72];
summaryColor = [0.10, 0.55, 0.34];

%% ======================== 读取 CSV 文件 ========================

[csvFiles, discoveryInfo] = resolveCsvFiles( ...
    inputMode, inputPath, filePattern, includeSubfolders, autoPickRule, scriptDir);

if isempty(csvFiles)
    error('没有找到可用于分析的 CSV 文件。');
end

fprintf('读取模式：%s\n', discoveryInfo.mode);
fprintf('搜索路径：%s\n', discoveryInfo.rootPath);
fprintf('匹配到的 CSV 文件数：%d\n', numel(csvFiles));
for i = 1:numel(csvFiles)
    fprintf('  [%d] %s\n', i, csvFiles{i});
end

%% ======================== 逐文件解析扫描结果 ========================

runs = struct([]);
skippedFiles = strings(0, 1);

for i = 1:numel(csvFiles)
    currentRun = loadUTrimScanRun( ...
        csvFiles{i}, ...
        primaryZeroSolveMethod, ...
        fallbackZeroSolveMethod);

    if currentRun.validPointCount < 2
        skippedFiles(end + 1, 1) = string(currentRun.fileName); %#ok<AGROW>
        fprintf('跳过文件（有效 point_summary 点不足 2 个）：%s\n', currentRun.filePath);
        continue;
    end

    if isempty(runs)
        runs = currentRun;
    else
        runs(end + 1) = currentRun; %#ok<AGROW>
    end
end

if isempty(runs)
    error('所有 CSV 都未能解析出足够的 point_summary 扫描点。');
end

%% ======================== 结果汇总 ========================

summaryTable = buildSummaryTable(runs);

fprintf('\n每次实验的直行补偿结果：\n');
disp(summaryTable);
fprintf('说明：PWM半差值舍弃小数部分；summaryTable.TrimU 仍保留精确半差值。\n');
for i = 1:height(summaryTable)
    fprintf('  [%d] %s: TrimPwmDiff = %.6f, U = %d\n', ...
        i, summaryTable.FileName(i), summaryTable.TrimPwmDiff(i), fix(summaryTable.TrimU(i)));
end

allPwmDiff = vertcat(runs.scanPwmDiff);
allYawRate = vertcat(runs.scanYawRateMeanDegPerSec);

aggregateStats = buildAggregateStats(allPwmDiff, allYawRate);
aggregateTable = table( ...
    aggregateStats.pwmDiff, ...
    aggregateStats.meanYawRate, ...
    aggregateStats.sampleCount, ...
    aggregateStats.stdYawRate, ...
    aggregateStats.semYawRate, ...
    'VariableNames', { ...
    'PwmDiff', 'MeanYawRateDegPerSec', 'SampleCount', ...
    'StdYawRateDegPerSec', 'SemYawRateDegPerSec'});
aggregateFit = fitAggregateTrend( ...
    aggregateStats, aggregateFitDegree, summaryTable.TrimPwmDiff);

fprintf('\n各 PWM 差值对应的角速度均值统计：\n');
disp(aggregateTable);

results = struct();
results.generatedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
results.discoveryInfo = discoveryInfo;
results.csvFiles = csvFiles;
results.skippedFiles = skippedFiles;
results.runs = runs;
results.summaryTable = summaryTable;
results.aggregateStats = aggregateStats;
results.aggregateTable = aggregateTable;
results.aggregateFit = aggregateFit;
results.config = struct( ...
    'inputMode', inputMode, ...
    'inputPath', inputPath, ...
    'filePattern', filePattern, ...
    'includeSubfolders', includeSubfolders, ...
    'autoPickRule', autoPickRule, ...
    'showControllerOutputFigure', showControllerOutputFigure, ...
    'showYawRateTimeFigure', showYawRateTimeFigure, ...
    'primaryZeroSolveMethod', primaryZeroSolveMethod, ...
    'fallbackZeroSolveMethod', fallbackZeroSolveMethod, ...
    'aggregateFitDegree', aggregateFitDegree);

%% ======================== 图 1：每次试验单独子图 ========================

figures = struct();

if showControllerOutputFigure
    figures.controllerOutput = figure('Name', 'Controller Output vs Time', 'Color', 'w');
    plotControllerOutputFigure(runs, lineWidth, referenceLineColor);
end

if showYawRateTimeFigure
    figures.yawRateTime = figure('Name', 'Yaw Rate vs Time', 'Color', 'w');
    plotYawRateTimeFigure(runs, lineWidth, markerSize, referenceLineColor);
end

%% ======================== 图 1：每次试验单独子图 ========================

if showPerRunFigure
    figures.perRun = figure('Name', 'Per-Run PWM Diff vs Yaw Rate', 'Color', 'w');
    plotPerRunSubplots( ...
        runs, lineWidth, markerSize, trimMarkerSize, referenceLineColor);
end

%% ======================== 图 2：所有试验叠加图 ========================

if showOverlayFigure
    figures.overlay = figure('Name', 'Overlay PWM Diff vs Yaw Rate', 'Color', 'w');
    plotOverlayFigure( ...
        runs, lineWidth, markerSize, trimMarkerSize, referenceLineColor);
end

%% ======================== 图 3：总体均值与拟合图 ========================

if showAggregateFigure
    figures.aggregate = figure('Name', 'Aggregate PWM Diff vs Yaw Rate', 'Color', 'w');
    plotAggregateFigure( ...
        aggregateStats, aggregateFit, aggregateColor, fitLineColor, ...
        aggregateMarkerSize, fitLineWidth, trimMarkerSize, referenceLineColor);
end

%% ======================== 图 4：直行补偿量汇总图 ========================

if showSummaryFigure
    figures.summary = figure('Name', 'Straight-Line Trim Summary', 'Color', 'w');
    plotSummaryFigure(summaryTable, summaryColor);
end

results.figures = figures;

%% ======================== 输出总体结论 ========================

fprintf('\n总体统计结果：\n');
fprintf('  扫描点总数：%d\n', numel(allPwmDiff));
fprintf('  唯一 PWM 差值数量：%d\n', numel(aggregateStats.pwmDiff));

if aggregateFit.available
    fprintf('  总体拟合：yawRate = %s\n', polynomialToString(aggregateFit.coeff, 'pwmDiff'));
    fprintf('  总体拟合得到的直行 PWM 全差值：%.6f\n', aggregateFit.zeroPwmDiff);
    fprintf('  PWM半差值：%d\n', fix(aggregateFit.zeroPwmDiff / 2));
    fprintf('  说明：PWM半差值舍弃小数部分，精确值为 %.6f。\n', ...
        aggregateFit.zeroPwmDiff / 2);
else
    fprintf('  总体拟合：未生成（唯一 PWM 差值点不足）。\n');
end

if ~isempty(skippedFiles)
    fprintf('\n被跳过的文件：\n');
    for i = 1:numel(skippedFiles)
        fprintf('  %s\n', skippedFiles(i));
    end
end

%% ======================== 可选保存区 ========================

if saveSummaryCsv || saveFigures
    resolvedOutputRoot = fullfile(scriptDir, outputRoot);
    ensureFolder(resolvedOutputRoot);
else
    resolvedOutputRoot = '';
end

if saveSummaryCsv
    summaryCsvPath = fullfile(resolvedOutputRoot, 'u_trim_scan_summary.csv');
    writetable(summaryTable, summaryCsvPath);
    results.summaryCsvPath = summaryCsvPath;
    fprintf('\n已保存汇总 CSV：%s\n', summaryCsvPath);
end

if saveFigures
    saveFigureBundle(figures, resolvedOutputRoot);
    results.figureOutputRoot = resolvedOutputRoot;
    fprintf('已导出图形到：%s\n', resolvedOutputRoot);
end

fprintf('\n分析完成。\n');

%% ======================== 本地函数区 ========================

function [csvFiles, discoveryInfo] = resolveCsvFiles(inputMode, inputPath, filePattern, includeSubfolders, autoPickRule, scriptDir)
% 解析输入模式，并返回待分析 CSV 列表。

    inputMode = lower(strtrim(char(string(inputMode))));
    csvFiles = {};
    discoveryInfo = struct('mode', inputMode, 'rootPath', '');

    switch inputMode
        case 'auto'
            experimentRoot = fullfile(scriptDir, 'experiment_tests');
            originRoot = fullfile(scriptDir, 'origin_experiment_test');

            if isfolder(experimentRoot)
                csvFiles = collectCsvFiles(experimentRoot, filePattern, includeSubfolders);
            end

            if ~isempty(csvFiles)
                discoveryInfo.mode = 'auto_experiment_tests';
                discoveryInfo.rootPath = experimentRoot;
                csvFiles = selectOneCsvFile(csvFiles, autoPickRule);
                return;
            end

            csvFiles = collectCsvFiles(originRoot, filePattern, includeSubfolders);
            discoveryInfo.mode = 'auto_origin_experiment_test';
            discoveryInfo.rootPath = originRoot;
            csvFiles = selectOneCsvFile(csvFiles, autoPickRule);

        case 'folder'
            resolvedPath = resolveInputPath(inputPath, scriptDir);
            if ~isfolder(resolvedPath)
                error('找不到输入文件夹：%s', resolvedPath);
            end
            csvFiles = collectCsvFiles(resolvedPath, filePattern, includeSubfolders);
            csvFiles = selectOneCsvFile(csvFiles, autoPickRule);
            discoveryInfo.rootPath = resolvedPath;

        case 'single'
            if isempty(strtrim(char(string(inputPath))))
                [csvFiles, discoveryInfo] = resolveCsvFiles( ...
                    'auto', '', filePattern, includeSubfolders, autoPickRule, scriptDir);
                discoveryInfo.mode = 'single_empty_fallback_auto';
                return;
            end

            resolvedPath = resolveInputPath(inputPath, scriptDir);
            if ~isfile(resolvedPath)
                error('找不到输入文件：%s', resolvedPath);
            end
            csvFiles = {resolvedPath};
            discoveryInfo.rootPath = resolvedPath;

        otherwise
            error('inputMode 仅支持 auto / folder / single。');
    end
end

function resolvedPath = resolveInputPath(inputPath, scriptDir)
% 优先按当前给定路径判断，找不到时再按脚本目录拼接。

    inputPath = char(string(inputPath));

    if isempty(strtrim(inputPath))
        resolvedPath = inputPath;
        return;
    end

    if isfile(inputPath) || isfolder(inputPath)
        resolvedPath = inputPath;
        return;
    end

    candidatePath = fullfile(scriptDir, inputPath);
    if isfile(candidatePath) || isfolder(candidatePath)
        resolvedPath = candidatePath;
    else
        resolvedPath = inputPath;
    end
end

function csvFiles = collectCsvFiles(folderPath, filePattern, includeSubfolders)
% 收集指定目录中的 CSV 文件，并按文件路径排序。

    if ~isfolder(folderPath)
        csvFiles = {};
        return;
    end

    if includeSubfolders
        entries = dir(fullfile(folderPath, '**', filePattern));
    else
        entries = dir(fullfile(folderPath, filePattern));
    end

    entries = entries(~[entries.isdir]);
    if isempty(entries)
        csvFiles = {};
        return;
    end

    fullPaths = strings(numel(entries), 1);
    for i = 1:numel(entries)
        fullPaths(i) = string(fullfile(entries(i).folder, entries(i).name));
    end

    [~, sortIdx] = sort(lower(fullPaths));
    fullPaths = fullPaths(sortIdx);
    csvFiles = cellstr(fullPaths);
end

function csvFiles = selectOneCsvFile(csvFiles, autoPickRule)
% 从候选 CSV 列表中选出 1 个文件。

    if isempty(csvFiles)
        return;
    end

    autoPickRule = lower(strtrim(char(string(autoPickRule))));
    if isempty(autoPickRule)
        autoPickRule = 'latest';
    end

    if numel(csvFiles) == 1
        return;
    end

    switch autoPickRule
        case 'latest'
            timeValues = nan(numel(csvFiles), 1);
            for i = 1:numel(csvFiles)
                dirInfo = dir(csvFiles{i});
                if ~isempty(dirInfo)
                    timeValues(i) = dirInfo(1).datenum;
                end
            end
            [~, idx] = max(timeValues);

        case 'name'
            [~, idx] = sort(lower(string(csvFiles)));
            idx = idx(end);

        otherwise
            error('autoPickRule 仅支持 latest / name。');
    end

    csvFiles = csvFiles(idx);
end

function run = loadUTrimScanRun(filePath, primaryMethod, fallbackMethod)
% 读取单个 u_trim_scan CSV，并提取 point_summary 扫描结果。

    tbl = safeReadTable(filePath);

    rowType = tableColumnToString(extractTableColumn(tbl, 'row_type'));
    timestamp = tableColumnToNumeric(extractTableColumn(tbl, 'timestamp'));
    wallTime = tableColumnToString(extractTableColumn(tbl, 'wall_time'));
    note = tableColumnToString(extractTableColumn(tbl, 'note'));
    phase = tableColumnToString(extractTableColumn(tbl, 'phase'));
    isAnalysisSample = tableColumnToNumeric(extractTableColumn(tbl, 'is_analysis_sample'));
    targetUInput = tableColumnToNumeric(extractTableColumn(tbl, 'target_u_input'));
    leftPwm = tableColumnToNumeric(extractTableColumn(tbl, 'left_pwm'));
    rightPwm = tableColumnToNumeric(extractTableColumn(tbl, 'right_pwm'));
    controlMode = tableColumnToNumeric(extractTableColumn(tbl, 'control_mode'));
    yawRateRaw = tableColumnToNumeric(extractTableColumn(tbl, 'yaw_rate_deg_s'));
    yawRateMean = tableColumnToNumeric(extractTableColumn(tbl, 'analysis_yaw_rate_mean_deg_s'));
    optimalUTrim = tableColumnToNumeric(extractTableColumn(tbl, 'optimal_u_trim'));

    pointMask = strcmpi(strtrim(rowType), 'point_summary');
    pointMask = pointMask & isfinite(leftPwm) & isfinite(rightPwm) & isfinite(yawRateMean);

    scanPwmDiff = rightPwm(pointMask) - leftPwm(pointMask);
    scanHalfDiffU = targetUInput(pointMask);
    scanYawRate = yawRateMean(pointMask);

    [scanPwmDiff, sortIdx] = sort(scanPwmDiff(:));
    scanHalfDiffU = scanHalfDiffU(sortIdx);
    scanYawRate = scanYawRate(sortIdx);

    [scanPwmDiff, scanHalfDiffU, scanYawRate] = mergeDuplicateScanPoints( ...
        scanPwmDiff, scanHalfDiffU, scanYawRate);

    sampleMask = strcmpi(strtrim(rowType), 'sample');
    sampleMask = sampleMask & isfinite(timestamp) & isfinite(yawRateRaw);

    sampleTimeSec = timestamp(sampleMask);
    sampleYawRateDegPerSec = yawRateRaw(sampleMask);
    samplePhase = phase(sampleMask);
    sampleAnalysisMask = isAnalysisSample(sampleMask) > 0;
    sampleTargetUInput = targetUInput(sampleMask);
    sampleLeftPwm = leftPwm(sampleMask);
    sampleRightPwm = rightPwm(sampleMask);
    samplePwmDiff = sampleRightPwm - sampleLeftPwm;
    sampleControlMode = controlMode(sampleMask);
    sampleOptimalUTrim = optimalUTrim(sampleMask);

    if ~isempty(sampleTimeSec)
        sampleTimeSec = sampleTimeSec - sampleTimeSec(1);
    end

    trim = estimateZeroCrossing(scanPwmDiff, scanYawRate, primaryMethod, fallbackMethod);
    trim.uValue = trim.pwmDiff / 2;

    finalMask = strcmpi(strtrim(rowType), 'final_result');
    finalMask = finalMask & isfinite(optimalUTrim);

    recordedOptimalU = NaN;
    recordedTrimPwmDiff = NaN;
    recordedNote = "";
    if any(finalMask)
        finalIndex = find(finalMask, 1, 'first');
        recordedOptimalU = optimalUTrim(finalIndex);
        recordedTrimPwmDiff = 2 * recordedOptimalU;
        recordedNote = note(finalIndex);
    end

    [~, fileName, ext] = fileparts(filePath);

    run = struct();
    run.filePath = filePath;
    run.fileName = [fileName ext];
    run.fileLabel = fileName;
    run.wallTimeStart = wallTime(1);
    run.wallTimeEnd = wallTime(end);
    run.validPointCount = numel(scanPwmDiff);
    run.scanPwmDiff = scanPwmDiff(:);
    run.scanHalfDiffU = scanHalfDiffU(:);
    run.scanYawRateMeanDegPerSec = scanYawRate(:);
    run.sampleTimeSec = sampleTimeSec(:);
    run.sampleYawRateDegPerSec = sampleYawRateDegPerSec(:);
    run.samplePhase = samplePhase(:);
    run.sampleIsAnalysisMask = logical(sampleAnalysisMask(:));
    run.sampleTargetUInput = sampleTargetUInput(:);
    run.sampleLeftPwm = sampleLeftPwm(:);
    run.sampleRightPwm = sampleRightPwm(:);
    run.samplePwmDiff = samplePwmDiff(:);
    run.sampleControlMode = sampleControlMode(:);
    run.sampleOptimalUTrim = sampleOptimalUTrim(:);
    run.trim = trim;
    run.recordedOptimalU = recordedOptimalU;
    run.recordedTrimPwmDiff = recordedTrimPwmDiff;
    run.recordedNote = recordedNote;
end

function tbl = safeReadTable(filePath)
% 读取 CSV 表格，优先保留文本列为 string。

    try
        tbl = readtable(filePath, 'TextType', 'string');
    catch
        tbl = readtable(filePath);
    end
end

function values = extractTableColumn(tbl, columnName)
% 按列名提取表格列，支持大小写与合法变量名兼容。

    variableNames = tbl.Properties.VariableNames;
    idx = matchColumnName(variableNames, columnName);

    if isempty(idx)
        error('CSV 中缺少必要列：%s', columnName);
    end

    values = tbl{:, idx};
end

function idx = matchColumnName(variableNames, requestedName)
% 匹配列名。

    idx = find(strcmp(variableNames, requestedName), 1, 'first');
    if ~isempty(idx)
        return;
    end

    idx = find(strcmpi(variableNames, requestedName), 1, 'first');
    if ~isempty(idx)
        return;
    end

    safeRequestedName = matlab.lang.makeValidName(requestedName);
    idx = find(strcmp(variableNames, safeRequestedName), 1, 'first');
    if ~isempty(idx)
        return;
    end

    idx = find(strcmpi(variableNames, safeRequestedName), 1, 'first');
end

function values = tableColumnToNumeric(values)
% 将表格列尽量转换为数值列向量。

    if istable(values)
        values = table2array(values);
    end

    if iscell(values)
        values = str2double(values);
    elseif isstring(values)
        values = str2double(values);
    elseif ischar(values)
        values = str2double(cellstr(values));
    elseif islogical(values)
        values = double(values);
    end

    if ~isnumeric(values)
        error('表格列无法转换为数值类型。');
    end

    values = values(:);
end

function values = tableColumnToString(values)
% 将表格列转换为 string 列向量。

    if isstring(values)
        values = values(:);
        return;
    end

    if iscell(values)
        values = string(values(:));
    elseif ischar(values)
        values = string(cellstr(values));
    elseif iscategorical(values)
        values = string(values(:));
    else
        values = string(values(:));
    end
end

function [xUnique, uUnique, yUnique] = mergeDuplicateScanPoints(xData, uData, yData)
% 对重复 PWM 差值进行合并，避免重复点影响零点求解。

    if isempty(xData)
        xUnique = [];
        uUnique = [];
        yUnique = [];
        return;
    end

    [xUnique, ~, groupIndex] = unique(xData(:), 'sorted');
    uUnique = accumarray(groupIndex, uData(:), [], @mean);
    yUnique = accumarray(groupIndex, yData(:), [], @mean);
end

function trim = estimateZeroCrossing(xData, yData, primaryMethod, fallbackMethod)
% 估计角速度为 0 时对应的 PWM 差值。

    trim = initTrimStruct();

    [trimValue, trimMeta] = trySolveZeroByMethod(xData, yData, primaryMethod);
    if ~trimMeta.success && ~strcmpi(primaryMethod, fallbackMethod)
        [trimValue, trimMeta] = trySolveZeroByMethod(xData, yData, fallbackMethod);
    end

    if trimMeta.success
        trim = trimMeta;
        trim.pwmDiff = trimValue;
    else
        trim.method = "unresolved";
        trim.pwmDiff = NaN;
    end
end

function trim = initTrimStruct()
% 构造默认零点求解结果结构体。

    trim = struct();
    trim.success = false;
    trim.method = "";
    trim.pwmDiff = NaN;
    trim.uValue = NaN;
    trim.residualYawRateDegPerSec = NaN;
    trim.bracketPwmDiff = [NaN, NaN];
    trim.bracketYawRate = [NaN, NaN];
    trim.fitCoeff = [];
end

function [pwmDiffAtZero, trimMeta] = trySolveZeroByMethod(xData, yData, methodName)
% 按指定方法求解零点。

    xData = xData(:);
    yData = yData(:);

    trimMeta = initTrimStruct();
    pwmDiffAtZero = NaN;

    if isempty(xData) || numel(xData) ~= numel(yData)
        return;
    end

    methodName = lower(strtrim(char(string(methodName))));

    switch methodName
        case 'linear'
            exactIdx = find(abs(yData) <= eps(max(1, max(abs(yData)))), 1, 'first');
            if ~isempty(exactIdx)
                pwmDiffAtZero = xData(exactIdx);
                trimMeta.success = true;
                trimMeta.method = "exact_scan_point";
                trimMeta.residualYawRateDegPerSec = yData(exactIdx);
                trimMeta.bracketPwmDiff = [xData(exactIdx), xData(exactIdx)];
                trimMeta.bracketYawRate = [yData(exactIdx), yData(exactIdx)];
                return;
            end

            candidateIdx = [];
            candidateScore = [];
            for i = 1:(numel(xData) - 1)
                y1 = yData(i);
                y2 = yData(i + 1);
                if y1 * y2 < 0
                    candidateIdx(end + 1, 1) = i; %#ok<AGROW>
                    candidateScore(end + 1, 1) = abs(y1) + abs(y2); %#ok<AGROW>
                end
            end

            if isempty(candidateIdx)
                return;
            end

            [~, bestLocalIdx] = min(candidateScore);
            i = candidateIdx(bestLocalIdx);

            x1 = xData(i);
            x2 = xData(i + 1);
            y1 = yData(i);
            y2 = yData(i + 1);

            pwmDiffAtZero = x1 + (0 - y1) * (x2 - x1) / (y2 - y1);
            trimMeta.success = true;
            trimMeta.method = "linear_interpolation";
            trimMeta.residualYawRateDegPerSec = 0;
            trimMeta.bracketPwmDiff = [x1, x2];
            trimMeta.bracketYawRate = [y1, y2];

        case 'poly1'
            if numel(xData) < 2
                return;
            end

            coeff = polyfit(xData, yData, 1);
            if abs(coeff(1)) <= eps(max(1, abs(coeff(1))))
                return;
            end

            pwmDiffAtZero = -coeff(2) / coeff(1);
            trimMeta.success = true;
            trimMeta.method = "poly1_fit";
            trimMeta.residualYawRateDegPerSec = polyval(coeff, pwmDiffAtZero);
            trimMeta.bracketPwmDiff = [min(xData), max(xData)];
            trimMeta.bracketYawRate = [polyval(coeff, min(xData)), polyval(coeff, max(xData))];
            trimMeta.fitCoeff = coeff;

        case 'poly2'
            if numel(xData) < 3
                return;
            end

            coeff = polyfit(xData, yData, 2);
            pwmDiffAtZero = selectPolynomialZero(coeff, [min(xData), max(xData)], mean(xData));
            if ~isfinite(pwmDiffAtZero)
                return;
            end

            trimMeta.success = true;
            trimMeta.method = "poly2_fit";
            trimMeta.residualYawRateDegPerSec = polyval(coeff, pwmDiffAtZero);
            trimMeta.bracketPwmDiff = [min(xData), max(xData)];
            trimMeta.bracketYawRate = [polyval(coeff, min(xData)), polyval(coeff, max(xData))];
            trimMeta.fitCoeff = coeff;

        case 'nearest'
            [~, nearestIdx] = min(abs(yData));
            pwmDiffAtZero = xData(nearestIdx);
            trimMeta.success = true;
            trimMeta.method = "nearest_scan_point";
            trimMeta.residualYawRateDegPerSec = yData(nearestIdx);
            trimMeta.bracketPwmDiff = [xData(nearestIdx), xData(nearestIdx)];
            trimMeta.bracketYawRate = [yData(nearestIdx), yData(nearestIdx)];

        otherwise
            error('未知零点求解方法：%s', methodName);
    end
end

function value = selectPolynomialZero(coeff, preferredRange, preferredCenter)
% 从多项式根中选择一个最合理的实根。

    if isempty(coeff) || all(abs(coeff) < eps)
        value = NaN;
        return;
    end

    allRoots = roots(coeff(:).');
    realRoots = real(allRoots(abs(imag(allRoots)) < 1e-9));

    if isempty(realRoots)
        value = NaN;
        return;
    end

    if nargin < 2 || isempty(preferredRange)
        preferredRange = [-inf, inf];
    end

    if nargin < 3 || ~isfinite(preferredCenter)
        preferredCenter = mean(preferredRange);
    end

    inRangeMask = realRoots >= preferredRange(1) - 1e-9 & realRoots <= preferredRange(2) + 1e-9;
    if any(inRangeMask)
        candidates = realRoots(inRangeMask);
    else
        candidates = realRoots;
    end

    [~, idx] = min(abs(candidates - preferredCenter));
    value = candidates(idx);
end

function summaryTable = buildSummaryTable(runs)
% 将每次实验的结果整理为 MATLAB table。

    runCount = numel(runs);

    fileName = strings(runCount, 1);
    wallTimeStart = strings(runCount, 1);
    wallTimeEnd = strings(runCount, 1);
    scanPointCount = zeros(runCount, 1);
    trimMethod = strings(runCount, 1);
    trimPwmDiff = nan(runCount, 1);
    trimU = nan(runCount, 1);
    residualYawRateDegPerSec = nan(runCount, 1);
    recordedOptimalU = nan(runCount, 1);
    recordedTrimPwmDiff = nan(runCount, 1);
    deltaUVsRecorded = nan(runCount, 1);
    deltaPwmDiffVsRecorded = nan(runCount, 1);
    recordedNote = strings(runCount, 1);

    for i = 1:runCount
        fileName(i) = string(runs(i).fileName);
        wallTimeStart(i) = string(runs(i).wallTimeStart);
        wallTimeEnd(i) = string(runs(i).wallTimeEnd);
        scanPointCount(i) = runs(i).validPointCount;
        trimMethod(i) = string(runs(i).trim.method);
        trimPwmDiff(i) = runs(i).trim.pwmDiff;
        trimU(i) = runs(i).trim.uValue;
        residualYawRateDegPerSec(i) = runs(i).trim.residualYawRateDegPerSec;
        recordedOptimalU(i) = runs(i).recordedOptimalU;
        recordedTrimPwmDiff(i) = runs(i).recordedTrimPwmDiff;
        deltaUVsRecorded(i) = runs(i).trim.uValue - runs(i).recordedOptimalU;
        deltaPwmDiffVsRecorded(i) = runs(i).trim.pwmDiff - runs(i).recordedTrimPwmDiff;
        recordedNote(i) = string(runs(i).recordedNote);
    end

    summaryTable = table( ...
        fileName, wallTimeStart, wallTimeEnd, scanPointCount, trimMethod, ...
        trimPwmDiff, trimU, residualYawRateDegPerSec, ...
        recordedOptimalU, recordedTrimPwmDiff, ...
        deltaUVsRecorded, deltaPwmDiffVsRecorded, recordedNote, ...
        'VariableNames', { ...
        'FileName', 'WallTimeStart', 'WallTimeEnd', 'ScanPointCount', 'TrimMethod', ...
        'TrimPwmDiff', 'TrimU', 'ResidualYawRateDegPerSec', ...
        'RecordedOptimalU', 'RecordedTrimPwmDiff', ...
        'DeltaUVsRecorded', 'DeltaPwmDiffVsRecorded', 'RecordedNote'});
end

function aggregateStats = buildAggregateStats(allPwmDiff, allYawRate)
% 对所有扫描点按唯一 PWM 差值做统计。

    allPwmDiff = allPwmDiff(:);
    allYawRate = allYawRate(:);

    [uniquePwmDiff, ~, groupIndex] = unique(allPwmDiff, 'sorted');

    groupCount = accumarray(groupIndex, 1);
    meanYawRate = accumarray(groupIndex, allYawRate, [], @mean);
    stdYawRate = accumarray(groupIndex, allYawRate, [], @safeStd);
    semYawRate = stdYawRate ./ sqrt(max(groupCount, 1));

    aggregateStats = struct();
    aggregateStats.pwmDiff = uniquePwmDiff;
    aggregateStats.meanYawRate = meanYawRate;
    aggregateStats.stdYawRate = stdYawRate;
    aggregateStats.semYawRate = semYawRate;
    aggregateStats.sampleCount = groupCount;
end

function fitResult = fitAggregateTrend(aggregateStats, fitDegree, trimPwmDiffValues)
% 对总体均值点做加权拟合，并给出零点估计。

    fitResult = struct();
    fitResult.available = false;
    fitResult.coeff = [];
    fitResult.xFit = [];
    fitResult.yFit = [];
    fitResult.zeroPwmDiff = NaN;

    xData = aggregateStats.pwmDiff(:);
    yData = aggregateStats.meanYawRate(:);
    weights = aggregateStats.sampleCount(:);

    if numel(xData) < fitDegree + 1
        return;
    end

    coeff = weightedPolyfit(xData, yData, fitDegree, weights);
    xFit = linspace(min(xData), max(xData), 400).';
    yFit = polyval(coeff, xFit);

    preferredCenter = mean(trimPwmDiffValues(isfinite(trimPwmDiffValues)));
    if isempty(preferredCenter) || ~isfinite(preferredCenter)
        preferredCenter = mean(xData);
    end

    zeroPwmDiff = selectPolynomialZero(coeff, [min(xData), max(xData)], preferredCenter);

    fitResult.available = true;
    fitResult.coeff = coeff;
    fitResult.xFit = xFit;
    fitResult.yFit = yFit;
    fitResult.zeroPwmDiff = zeroPwmDiff;
end

function stdValue = safeStd(values)
% 计算标准差；当样本数小于 2 时返回 0。

    values = values(:);
    if numel(values) <= 1
        stdValue = 0;
    else
        stdValue = std(values, 0);
    end
end

function coeff = weightedPolyfit(xData, yData, degree, weights)
% 加权多项式拟合。

    xData = xData(:);
    yData = yData(:);
    weights = weights(:);

    if numel(xData) ~= numel(yData) || numel(xData) ~= numel(weights)
        error('weightedPolyfit 输入长度不一致。');
    end

    vandermondeMatrix = zeros(numel(xData), degree + 1);
    for powerIndex = 0:degree
        vandermondeMatrix(:, degree - powerIndex + 1) = xData .^ powerIndex;
    end

    sqrtWeights = sqrt(weights);
    weightedMatrix = vandermondeMatrix .* sqrtWeights;
    weightedTarget = yData .* sqrtWeights;
    coeff = weightedMatrix \ weightedTarget;
    coeff = coeff.';
end

function plotControllerOutputFigure(runs, lineWidth, referenceLineColor)
% 绘制控制器输出随时间变化图。
% 上图：target_u_input / optimal_u_trim / pwmDiff
% 下图：left_pwm / right_pwm / control_mode

    runCount = numel(runs);
    if runCount ~= 1
        hold on;
        colorMap = lines(runCount);
        for i = 1:runCount
            plot(runs(i).sampleTimeSec, runs(i).samplePwmDiff, '-', ...
                'Color', colorMap(i, :), ...
                'LineWidth', lineWidth, ...
                'DisplayName', sprintf('%s pwmDiff', runs(i).fileLabel));
        end
        yline(0, '--', 'Color', referenceLineColor, 'LineWidth', 1.0, ...
            'HandleVisibility', 'off');
        applyThesisAxesStyle();
        xlabel('Time (s)');
        ylabel('PWM diff');
        legend('Location', 'best', 'Interpreter', 'none');
        hold off;
        return;
    end

    run = runs(1);

    if exist('tiledlayout', 'file') == 2 || exist('tiledlayout', 'builtin') == 5
        tileLayout = tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
        ax1 = nexttile(tileLayout, 1);
        ax2 = nexttile(tileLayout, 2);
    else
        ax1 = subplot(2, 1, 1);
        ax2 = subplot(2, 1, 2);
    end

    axes(ax1);
    hold(ax1, 'on');
    plot(ax1, run.sampleTimeSec, run.sampleTargetUInput, '-', ...
        'Color', [0.10, 0.35, 0.78], ...
        'LineWidth', lineWidth, ...
        'DisplayName', 'target u input');
    plot(ax1, run.sampleTimeSec, run.samplePwmDiff, '-', ...
        'Color', [0.82, 0.10, 0.10], ...
        'LineWidth', lineWidth, ...
        'DisplayName', 'pwmDiff');

    validOptimalMask = isfinite(run.sampleOptimalUTrim);
    if any(validOptimalMask)
        plot(ax1, run.sampleTimeSec(validOptimalMask), 2 * run.sampleOptimalUTrim(validOptimalMask), '--', ...
            'Color', [0.10, 0.55, 0.34], ...
            'LineWidth', lineWidth, ...
            'DisplayName', '2 * optimal u trim');
    end

    yline(ax1, 0, '--', 'Color', referenceLineColor, 'LineWidth', 1.0, ...
        'HandleVisibility', 'off');
    applyThesisAxesStyle();
    ylabel(ax1, 'Command / PWM diff');
    legend(ax1, 'Location', 'best');
    hold(ax1, 'off');

    axes(ax2);
    hold(ax2, 'on');
    plot(ax2, run.sampleTimeSec, run.sampleLeftPwm, '-', ...
        'Color', [0.12, 0.40, 0.72], ...
        'LineWidth', lineWidth, ...
        'DisplayName', 'left PWM');
    plot(ax2, run.sampleTimeSec, run.sampleRightPwm, '-', ...
        'Color', [0.82, 0.10, 0.10], ...
        'LineWidth', lineWidth, ...
        'DisplayName', 'right PWM');
    stairs(ax2, run.sampleTimeSec, run.sampleControlMode, '--', ...
        'Color', [0.30, 0.30, 0.30], ...
        'LineWidth', 1.0, ...
        'DisplayName', 'control mode');
    applyThesisAxesStyle();
    xlabel(ax2, 'Time (s)');
    ylabel(ax2, 'PWM / Mode');
    legend(ax2, 'Location', 'best');
    hold(ax2, 'off');
end

function plotYawRateTimeFigure(runs, lineWidth, markerSize, referenceLineColor)
% 绘制角速度随时间变化图，时间轴使用相对时间（秒）。

    runCount = numel(runs);
    colorMap = lines(runCount);

    if runCount == 1
        hold on;
        plot(runs(1).sampleTimeSec, runs(1).sampleYawRateDegPerSec, '-', ...
            'Color', colorMap(1, :), ...
            'LineWidth', lineWidth, ...
            'DisplayName', '角速度');

        if any(runs(1).sampleIsAnalysisMask)
            plot(runs(1).sampleTimeSec(runs(1).sampleIsAnalysisMask), ...
                runs(1).sampleYawRateDegPerSec(runs(1).sampleIsAnalysisMask), '.', ...
                'Color', [0.82, 0.10, 0.10], ...
                'MarkerSize', markerSize + 3, ...
                'DisplayName', 'analysis sample');
        end

        yline(0, '--', 'Color', referenceLineColor, 'LineWidth', 1.0, ...
            'HandleVisibility', 'off');
        applyThesisAxesStyle();
        xlabel('Time (s)');
        ylabel('Yaw Rate (deg/s)');
        legend('Location', 'best');
        hold off;
        return;
    end

    [numRows, numCols] = calcSubplotLayout(runCount);
    if exist('tiledlayout', 'file') == 2 || exist('tiledlayout', 'builtin') == 5
        tileLayout = tiledlayout(numRows, numCols, 'TileSpacing', 'compact', 'Padding', 'compact');
    else
        tileLayout = [];
    end

    for i = 1:runCount
        if isempty(tileLayout)
            subplot(numRows, numCols, i);
        else
            nexttile(tileLayout, i);
        end

        hold on;
        plot(runs(i).sampleTimeSec, runs(i).sampleYawRateDegPerSec, '-', ...
            'Color', colorMap(i, :), ...
            'LineWidth', lineWidth, ...
            'DisplayName', '角速度');

        if any(runs(i).sampleIsAnalysisMask)
            plot(runs(i).sampleTimeSec(runs(i).sampleIsAnalysisMask), ...
                runs(i).sampleYawRateDegPerSec(runs(i).sampleIsAnalysisMask), '.', ...
                'Color', [0.82, 0.10, 0.10], ...
                'MarkerSize', markerSize + 3, ...
                'DisplayName', 'analysis sample');
        end

        yline(0, '--', 'Color', referenceLineColor, 'LineWidth', 1.0, ...
            'HandleVisibility', 'off');
        applyThesisAxesStyle();
        xlabel('Time (s)');
        ylabel('Yaw Rate (deg/s)');
        legend('Location', 'best');
        hold off;
    end

    if ~isempty(tileLayout)
    end
end

function plotPerRunSubplots(runs, lineWidth, markerSize, trimMarkerSize, referenceLineColor)
% 绘制每次试验的 PWM 差值-角速度子图。

    runCount = numel(runs);
    [numRows, numCols] = calcSubplotLayout(runCount);
    colorMap = lines(runCount);

    if exist('tiledlayout', 'file') == 2 || exist('tiledlayout', 'builtin') == 5
        tileLayout = tiledlayout(numRows, numCols, 'TileSpacing', 'compact', 'Padding', 'compact');
    else
        tileLayout = [];
    end

    for i = 1:runCount
        if isempty(tileLayout)
            subplot(numRows, numCols, i);
        else
            nexttile(tileLayout, i);
        end

        hold on;
        plot(runs(i).scanPwmDiff, runs(i).scanYawRateMeanDegPerSec, '-o', ...
            'Color', colorMap(i, :), ...
            'LineWidth', lineWidth, ...
            'MarkerSize', markerSize, ...
            'MarkerFaceColor', colorMap(i, :), ...
            'DisplayName', '扫描点');

        yline(0, '--', 'Color', referenceLineColor, 'LineWidth', 1.0, ...
            'HandleVisibility', 'off');

        if isfinite(runs(i).trim.pwmDiff)
            scatter(runs(i).trim.pwmDiff, 0, trimMarkerSize, 'd', ...
                'MarkerFaceColor', colorMap(i, :), ...
                'MarkerEdgeColor', 'k', ...
                'LineWidth', 0.8, ...
                'DisplayName', '直行补偿点');
        end

        applyThesisAxesStyle();
        xlabel('PWM diff = right PWM - left PWM');
        ylabel('Mean Yaw Rate (deg/s)');
        legend('Location', 'best');
        hold off;
    end

    if ~isempty(tileLayout)
    end
end

function plotOverlayFigure(runs, lineWidth, markerSize, trimMarkerSize, referenceLineColor)
% 绘制所有试验叠加图。

    hold on;
    colorMap = lines(numel(runs));

    for i = 1:numel(runs)
        plot(runs(i).scanPwmDiff, runs(i).scanYawRateMeanDegPerSec, '-o', ...
            'Color', colorMap(i, :), ...
            'LineWidth', lineWidth, ...
            'MarkerSize', markerSize, ...
            'MarkerFaceColor', colorMap(i, :), ...
            'DisplayName', runs(i).fileLabel);

        if isfinite(runs(i).trim.pwmDiff)
            scatter(runs(i).trim.pwmDiff, 0, trimMarkerSize, 'd', ...
                'MarkerFaceColor', colorMap(i, :), ...
                'MarkerEdgeColor', 'k', ...
                'LineWidth', 0.8, ...
                'HandleVisibility', 'off');
        end
    end

    yline(0, '--', 'Color', referenceLineColor, 'LineWidth', 1.0, ...
        'HandleVisibility', 'off');

    applyThesisAxesStyle();
    xlabel('PWM diff = right PWM - left PWM');
    ylabel('Mean Yaw Rate (deg/s)');
    legend('Location', 'bestoutside', 'Interpreter', 'none');
    hold off;
end

function plotAggregateFigure(aggregateStats, aggregateFit, aggregateColor, fitLineColor, ...
    aggregateMarkerSize, fitLineWidth, trimMarkerSize, referenceLineColor)
% 绘制总体均值点与拟合曲线。

    hold on;

    errorbar(aggregateStats.pwmDiff, aggregateStats.meanYawRate, aggregateStats.semYawRate, 'o', ...
        'Color', aggregateColor, ...
        'MarkerFaceColor', aggregateColor, ...
        'MarkerEdgeColor', aggregateColor, ...
        'LineWidth', 1.0, ...
        'MarkerSize', 5, ...
        'CapSize', 6, ...
        'DisplayName', '各 PWM 差值的均值 ± SEM');

    if aggregateFit.available
        plot(aggregateFit.xFit, aggregateFit.yFit, '-', ...
            'Color', fitLineColor, ...
            'LineWidth', fitLineWidth, ...
            'DisplayName', '加权拟合');

        if isfinite(aggregateFit.zeroPwmDiff)
            scatter(aggregateFit.zeroPwmDiff, 0, trimMarkerSize, 'd', ...
                'MarkerFaceColor', fitLineColor, ...
                'MarkerEdgeColor', 'k', ...
                'LineWidth', 0.8, ...
                'DisplayName', '总体直行补偿点');
        end
    end

    yline(0, '--', 'Color', referenceLineColor, 'LineWidth', 1.0, ...
        'HandleVisibility', 'off');

    applyThesisAxesStyle();
    xlabel('PWM diff = right PWM - left PWM');
    ylabel('Mean Yaw Rate (deg/s)');

    if aggregateFit.available && isfinite(aggregateFit.zeroPwmDiff)
    else
    end

    legend('Location', 'best');
    hold off;
end

function plotSummaryFigure(summaryTable, summaryColor)
% 绘制各次实验的直行补偿量汇总图。

    runCount = height(summaryTable);
    x = 1:runCount;

    bar(x, summaryTable.TrimPwmDiff, 0.72, ...
        'FaceColor', summaryColor, ...
        'EdgeColor', summaryColor, ...
        'DisplayName', '直行补偿 PWM diff');
    ylabel('Trim PWM diff');

    applyThesisAxesStyle();
    xticks(x);
    xticklabels(summaryTable.FileName);
    xtickangle(30);
    xlabel('CSV File');
    legend('Location', 'best');
end

function [numRows, numCols] = calcSubplotLayout(numPlots)
% 根据图数量自动给出较均衡的子图布局。

    numRows = ceil(sqrt(numPlots));
    numCols = ceil(numPlots / numRows);
end

function applyThesisAxesStyle()
% 统一坐标轴样式。

    grid on;
    box on;
    ax = gca;
    ax.LineWidth = 0.9;
    ax.FontSize = 11;
end

function saveFigureBundle(figures, outputRoot)
% 将生成的图导出为 PNG。

    figureNames = fieldnames(figures);
    for i = 1:numel(figureNames)
        currentFigure = figures.(figureNames{i});
        if isempty(currentFigure) || ~isgraphics(currentFigure)
            continue;
        end

        outputPath = fullfile(outputRoot, [figureNames{i} '.png']);
        if exist('exportgraphics', 'file') == 2 || exist('exportgraphics', 'builtin') == 5
            exportgraphics(currentFigure, outputPath, 'Resolution', 180);
        else
            saveas(currentFigure, outputPath);
        end
    end
end

function ensureFolder(folderPath)
% 确保目录存在。

    if ~isfolder(folderPath)
        mkdir(folderPath);
    end
end

function textStr = polynomialToString(coeff, variableSymbol)
% 将多项式系数向量转成便于显示的字符串。

    degree = numel(coeff) - 1;
    parts = strings(size(coeff));

    for i = 1:numel(coeff)
        currentCoeff = coeff(i);
        currentPower = degree - (i - 1);

        if currentPower > 1
            parts(i) = sprintf('%.6g*%s^%d', currentCoeff, variableSymbol, currentPower);
        elseif currentPower == 1
            parts(i) = sprintf('%.6g*%s', currentCoeff, variableSymbol);
        else
            parts(i) = sprintf('%.6g', currentCoeff);
        end
    end

    textStr = strjoin(parts, ' + ');
    textStr = strrep(textStr, '+ -', '- ');
end
