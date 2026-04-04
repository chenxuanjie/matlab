function results = plot_ai_pid_heading_curves(varargin)
%PLOT_AI_PID_HEADING_CURVES 绘制 AI PID 航向角曲线，并支持双 CSV 对比。
%
% 用法：
%   results = plot_ai_pid_heading_curves()
%   results = plot_ai_pid_heading_curves('experiment_tests')
%   results = plot_ai_pid_heading_curves('experiment_tests/ai_pid')
%   results = plot_ai_pid_heading_curves('experiment_tests/pid')
%   results = plot_ai_pid_heading_curves('experiment_tests/run_a.csv')
%   results = plot_ai_pid_heading_curves('experiment_tests/ai_pid', 'experiment_tests/pid')
%   results = plot_ai_pid_heading_curves({'run_a.csv', 'run_b.csv'})
%   results = plot_ai_pid_heading_curves({'experiment_tests/ai_pid', 'experiment_tests/pid'})
%   results = plot_ai_pid_heading_curves(..., opts)
%
% 说明：
% 1. 不传输入时，会按“用户配置区”里的读取模式选择 ai_pid、pid 或两者对比。
% 2. 自动模式只会选择最新的 1 个 CSV 文件。
% 3. 显式传入文件夹时，会读取该文件夹下最新的 1 个可用 CSV。
% 4. 显式传入 2 个 CSV 或 2 个文件夹时，会生成对比图。
% 5. 如果 CSV 包含 kp/ki/kd 列，会额外生成增益随时间变化图。
% 6. CSV 至少需要包含：时间列、当前航向角列、期望航向角列。
%
% 常用可选项（opts）：
%   opts.OutputRoot            -> 结果输出目录，默认 ai_pid/results
%   opts.ReadMode              -> 读取模式，可选 ai_pid / pid / compare
%   opts.ShowFigures           -> true/false，是否显示图窗
%   opts.SaveEpsFigures        -> true/false，是否额外保存 .eps 矢量图
%   opts.NormalizeTimeToZero   -> true/false，是否让时间从 0 秒起
%   opts.UnwrapHeading         -> true/false，是否对航向角做展开显示
%   opts.Delimiter             -> CSV 分隔符，留空表示自动判断
%   opts.TimeColumn            -> 指定时间列名或列序号
%   opts.CurrentHeadingColumn  -> 指定当前航向角列名或列序号
%   opts.ExpectedHeadingColumn -> 指定期望航向角列名或列序号
%   opts.SettlingBandRatio     -> 稳定时间误差带比例，默认 0.02
%   opts.SettlingBandMinDeg    -> 稳定时间最小误差带，默认 1 deg

    %% ======================== 用户配置区（可直接修改） ========================
    % 默认输入路径。留空表示按下面的读取模式自动选择文件。
    defaultCsvInputs = {};
    % 读取模式。可选 ai_pid / pid / compare。
    readMode = 'compare';
    % 是否显示图窗。true 为显示，false 为只保存不弹出。
    showFigures = true;
    % 是否额外保存 EPS 矢量图
    saveEpsFigures = true;
    % 是否把时间轴统一平移到从 0 秒开始。
    normalizeTimeToZero = true;
    % 是否对航向角做展开，避免在 -180/180 附近跳变。
    unwrapHeading = true;
    % 结果输出目录。留空表示使用脚本目录下的 results 文件夹。
    outputRoot = '';
    % CSV 分隔符。留空表示自动判断。
    delimiter = '';
    % 时间列名。留空表示按内置候选列自动匹配。
    timeColumn = '';
    % 当前航向角列名。留空表示按内置候选列自动匹配。
    currentHeadingColumn = '';
    % 期望航向角列名。留空表示按内置候选列自动匹配。
    expectedHeadingColumn = '';
    % 稳定时间判据中的相对误差带比例，例如 0.02 表示 2%。
    settlingBandRatio = 0.02;
    % 稳定时间判据中的最小绝对误差带，单位 deg。
    settlingBandMinDeg = 1.0;
    %% ======================== 用户配置区结束 ========================

    [csvInputs, opts] = parseMainInputs(varargin, defaultCsvInputs);

    scriptDir = fileparts(mfilename('fullpath'));
    cfg = buildConfig(scriptDir, opts, showFigures, saveEpsFigures, ...
        normalizeTimeToZero, unwrapHeading, outputRoot, readMode, delimiter, ...
        timeColumn, currentHeadingColumn, expectedHeadingColumn, ...
        settlingBandRatio, settlingBandMinDeg);

    ensureFolder(cfg.OutputRoot);
    ensureFolder(cfg.RunOutputRoot);

    [selectedFiles, resolvedSearchRoot, discoveryMode] = resolveInputFiles(csvInputs, cfg);
    if isempty(selectedFiles)
        error('没有找到可用于绘图的 CSV 文件。');
    end

    fprintf('本次选中的 CSV 文件如下：%s\n', newline);
    for i = 1:numel(selectedFiles)
        fprintf('  文件 %d -> %s\n', i, selectedFiles(i).filePath);
    end

    datasets = struct([]);
    for i = 1:numel(selectedFiles)
        oneData = readHeadingCsv(selectedFiles(i).filePath, cfg);
        if isempty(datasets)
            datasets = oneData;
        else
            datasets(end + 1) = oneData; %#ok<AGROW>
        end
    end

    if numel(datasets) == 1
        figureFiles = plotSingleHeadingFigure(datasets, cfg);
    else
        figureFiles = struct();
        figureFiles.compare = plotDualHeadingFigure(datasets, cfg);
        usedFieldNames = fieldnames(figureFiles);
        for i = 1:numel(datasets)
            fieldName = buildSingleFigureFieldName(datasets(i), i, usedFieldNames);
            figureFiles.(fieldName) = plotSingleHeadingFigure(datasets(i), cfg);
            usedFieldNames = fieldnames(figureFiles);
        end
    end

    results = struct();
    results.generated_at = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    results.discovery_mode = discoveryMode;
    results.search_root = resolvedSearchRoot;
    results.output_root = cfg.RunOutputRoot;
    results.selected_files = selectedFiles;
    results.runs = datasets;
    results.figure_files = figureFiles;
    results.comparison_summary = buildComparisonSummary(datasets);
    results.summary_files = saveSummaryArtifacts(results, cfg);

    fprintf('\n航向角曲线结果汇总：\n');
    if results.comparison_summary.available
        fprintf('  ai_pid 文件: %s\n', results.comparison_summary.ai_pid_path);
        fprintf('  pid 文件: %s\n', results.comparison_summary.pid_path);
        fprintf('%s\n', buildComparisonSummaryText(results.comparison_summary));
    else
        for i = 1:numel(datasets)
            fprintf('  [%d] %s\n', i, datasets(i).filePath);
            fprintf('      均方根误差 = %.6f deg\n', datasets(i).metrics.rmse_deg);
            fprintf('      平均绝对误差 = %.6f deg\n', datasets(i).metrics.mae_deg);
            fprintf('      最大绝对误差 = %.6f deg\n', datasets(i).metrics.max_abs_error_deg);
            fprintf('      上升时间(10%%-90%%) = %s s\n', formatNumericText(datasets(i).responseMetrics.rise_time_s));
            fprintf('      最大超调时间 = %s s\n', formatNumericText(datasets(i).responseMetrics.peak_time_s));
            fprintf('      超调量 = %s deg (%s%%)\n', ...
                formatNumericText(datasets(i).responseMetrics.overshoot_deg), ...
                formatNumericText(datasets(i).responseMetrics.overshoot_percent));
            fprintf('      稳定时间(收敛时间) = %s s\n', formatNumericText(datasets(i).responseMetrics.settling_time_s));
            fprintf('      稳态误差 = %s deg\n', formatNumericText(datasets(i).responseMetrics.steady_state_error_deg));
            fprintf('      稳态平均绝对误差 = %s deg\n', formatNumericText(datasets(i).responseMetrics.steady_state_abs_error_deg));
        end
    end
    fprintf('  输出目录: %s\n', cfg.RunOutputRoot);
end

function cfg = buildConfig(scriptDir, opts, showFigures, saveEpsFigures, ...
    normalizeTimeToZero, unwrapHeading, outputRoot, readMode, delimiter, ...
    timeColumn, currentHeadingColumn, expectedHeadingColumn, ...
    settlingBandRatio, settlingBandMinDeg)

cfg = struct();
cfg.ScriptDir = scriptDir;
cfg.ProjectRoot = scriptDir;
cfg.OutputRoot = getPathOption(opts, 'OutputRoot', fullfile(scriptDir, 'results'), outputRoot);
cfg.OutputRoot = resolveFolderPath(cfg.OutputRoot, scriptDir);
cfg.RunStamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
cfg.RunOutputRoot = fullfile(cfg.OutputRoot, ['run_' cfg.RunStamp]);
cfg.ShowFigures = logical(getOption(opts, 'ShowFigures', showFigures));
cfg.SaveEpsFigures = logical(getOption(opts, 'SaveEpsFigures', saveEpsFigures));
cfg.NormalizeTimeToZero = logical(getOption(opts, 'NormalizeTimeToZero', normalizeTimeToZero));
cfg.UnwrapHeading = logical(getOption(opts, 'UnwrapHeading', unwrapHeading));
cfg.ReadMode = parseReadMode(getOption(opts, 'ReadMode', readMode));
cfg.Delimiter = strtrim(char(string(getOption(opts, 'Delimiter', delimiter))));
cfg.TimeColumn = getOption(opts, 'TimeColumn', timeColumn);
cfg.CurrentHeadingColumn = getOption(opts, 'CurrentHeadingColumn', currentHeadingColumn);
cfg.ExpectedHeadingColumn = getOption(opts, 'ExpectedHeadingColumn', expectedHeadingColumn);
cfg.SettlingBandRatio = getNumericScalarOption(opts, 'SettlingBandRatio', settlingBandRatio);
cfg.SettlingBandMinDeg = getNumericScalarOption(opts, 'SettlingBandMinDeg', settlingBandMinDeg);
cfg.MaxFileCount = 2;
cfg.LineWidth = 1.4;
cfg.CurrentColor = [0.10, 0.35, 0.78];
cfg.ExpectedColor = [0.88, 0.33, 0.12];
cfg.ErrorColor = [0.14, 0.56, 0.36];
cfg.SecondRunColor = [0.60, 0.24, 0.68];
cfg.ReferenceColor = [0.35, 0.35, 0.35];
cfg.PwmDiffColor = [0.78, 0.22, 0.18];
cfg.GainKpColor = [0.12, 0.38, 0.78];
cfg.GainKiColor = [0.86, 0.44, 0.15];
cfg.GainKdColor = [0.20, 0.62, 0.36];
cfg.DisplayFontName = getPreferredChineseFontName();
end

function [selectedFiles, resolvedSearchRoot, discoveryMode] = resolveInputFiles(csvInputs, cfg)
selectedFiles = struct([]);
resolvedSearchRoot = '';
discoveryMode = '';

inputItems = normalizeInputItems(csvInputs);
if isempty(inputItems)
    [selectedFiles, resolvedSearchRoot, discoveryMode] = resolveByReadMode(cfg);
    return;
end

if numel(inputItems) > cfg.MaxFileCount
    error('最多只支持 2 个 CSV 文件输入。');
end

resolvedSources = strings(0, 1);
folderInputCount = 0;
fileInputCount = 0;

for i = 1:numel(inputItems)
    resolvedPath = resolveInputPath(inputItems{i}, cfg.ScriptDir);
    if isfolder(resolvedPath)
        catalog = collectHeadingCsvFiles(resolvedPath, cfg);
        if isempty(catalog)
            error('在文件夹中没有发现包含时间/当前航向角/期望航向角列的 CSV：%s', resolvedPath);
        end
        meta = selectLatestCsvFiles(catalog, 1);
        folderInputCount = folderInputCount + 1;
        resolvedSources(end + 1, 1) = string(resolvedPath); %#ok<AGROW>
    else
        if ~isfile(resolvedPath)
            error('找不到 CSV 文件：%s', resolvedPath);
        end

        dirEntry = dir(resolvedPath);
        meta = inspectHeadingCsv(resolvedPath, dirEntry, cfg);
        if isempty(meta)
            error('CSV 缺少必要列，至少需要时间列、当前航向角列、期望航向角列：%s', resolvedPath);
        end

        fileInputCount = fileInputCount + 1;
        resolvedSources(end + 1, 1) = string(resolvedPath); %#ok<AGROW>
    end

    if isempty(selectedFiles)
        selectedFiles = meta;
    else
        selectedFiles(end + 1) = meta; %#ok<AGROW>
    end
end

resolvedSearchRoot = char(strjoin(resolvedSources, ' | '));
if folderInputCount == numel(inputItems) && numel(inputItems) == 1
    discoveryMode = 'folder_latest';
elseif folderInputCount == numel(inputItems)
    discoveryMode = 'folder_latest_compare';
elseif fileInputCount == numel(inputItems)
    discoveryMode = 'explicit_files';
else
    discoveryMode = 'mixed_inputs';
end
end

function [selectedFiles, resolvedSearchRoot, discoveryMode] = resolveByReadMode(cfg)
selectedFiles = struct([]);
resolvedSearchRoot = '';

experimentRoot = fullfile(cfg.ProjectRoot, 'experiment_tests');
aiPidRoot = fullfile(experimentRoot, 'ai_pid');
pidRoot = fullfile(experimentRoot, 'pid');

switch cfg.ReadMode
    case 'ai_pid'
        catalog = collectHeadingCsvFiles(aiPidRoot, cfg);
        if isempty(catalog)
            error('在 experiment_tests/ai_pid 中没有找到可用 CSV。');
        end
        selectedFiles = selectLatestCsvFiles(catalog, 1);
        resolvedSearchRoot = aiPidRoot;
        discoveryMode = 'config_ai_pid';

    case 'pid'
        catalog = collectHeadingCsvFiles(pidRoot, cfg);
        if isempty(catalog)
            error('在 experiment_tests/pid 中没有找到可用 CSV。');
        end
        selectedFiles = selectLatestCsvFiles(catalog, 1);
        resolvedSearchRoot = pidRoot;
        discoveryMode = 'config_pid';

    case 'compare'
        aiCatalog = collectHeadingCsvFiles(aiPidRoot, cfg);
        pidCatalog = collectHeadingCsvFiles(pidRoot, cfg);
        if isempty(aiCatalog)
            error('在 experiment_tests/ai_pid 中没有找到可用 CSV，无法做对比。');
        end
        if isempty(pidCatalog)
            error('在 experiment_tests/pid 中没有找到可用 CSV，无法做对比。');
        end
        aiSelected = selectLatestCsvFiles(aiCatalog, 1);
        pidSelected = selectLatestCsvFiles(pidCatalog, 1);
        selectedFiles = [aiSelected, pidSelected];
        resolvedSearchRoot = [aiPidRoot ' | ' pidRoot];
        discoveryMode = 'config_compare';

    otherwise
        error('不支持的读取模式：%s', cfg.ReadMode);
end
end

function catalog = collectHeadingCsvFiles(searchRoot, cfg)
catalog = struct([]);
if ~isfolder(searchRoot)
    return;
end

entries = dir(fullfile(searchRoot, '**', '*.csv'));
if isempty(entries)
    return;
end

for i = 1:numel(entries)
    filePath = fullfile(entries(i).folder, entries(i).name);
    meta = inspectHeadingCsv(filePath, entries(i), cfg);
    if isempty(meta)
        continue;
    end

    if isempty(catalog)
        catalog = meta;
    else
        catalog(end + 1) = meta; %#ok<AGROW>
    end
end
end

function meta = inspectHeadingCsv(filePath, dirEntry, cfg)
meta = struct([]);

try
    tbl = safeReadTable(filePath, cfg);
catch
    return;
end

names = normalizeNames(tbl.Properties.VariableNames);
if ~hasMatchingColumn(names, buildCandidateList(cfg.TimeColumn, defaultTimeColumnCandidates()))
    return;
end
if ~hasMatchingColumn(names, buildCandidateList(cfg.CurrentHeadingColumn, defaultCurrentHeadingCandidates()))
    return;
end
if ~hasMatchingColumn(names, buildCandidateList(cfg.ExpectedHeadingColumn, defaultExpectedHeadingCandidates()))
    return;
end

timestampText = extractTimestampText(filePath);
if isempty(timestampText)
    dt = datetime(dirEntry.datenum, 'ConvertFrom', 'datenum');
    timestampValue = posixtime(dt);
    timestampLabel = char(datetime(dt, 'Format', 'yyyy-MM-dd HH:mm:ss'));
else
    dt = datetime(timestampText, 'InputFormat', 'yyyyMMdd_HHmmss');
    timestampValue = posixtime(dt);
    timestampLabel = timestampText;
end

meta = struct();
meta.filePath = filePath;
meta.fileName = dirEntry.name;
meta.timestampValue = timestampValue;
meta.timestampLabel = timestampLabel;
end

function selected = selectLatestCsvFiles(catalog, desiredCount)
if nargin < 2 || isempty(desiredCount)
    desiredCount = 1;
end

[~, order] = sort([catalog.timestampValue], 'descend');
order = order(1:min(desiredCount, numel(order)));
selected = catalog(order);
end

function data = readHeadingCsv(filePath, cfg)
tbl = safeReadTable(filePath, cfg);
names = normalizeNames(tbl.Properties.VariableNames);

[timeS, timeColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, cfg.TimeColumn, defaultTimeColumnCandidates(), true);
[currentHeadingRawDeg, currentColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, cfg.CurrentHeadingColumn, defaultCurrentHeadingCandidates(), true);
[expectedHeadingRawDeg, expectedColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, cfg.ExpectedHeadingColumn, defaultExpectedHeadingCandidates(), true);
[loggedHeadingErrorDeg, loggedErrorColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, '', defaultErrorColumnCandidates(), false);
[kpValues, kpColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, '', defaultKpColumnCandidates(), false);
[kiValues, kiColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, '', defaultKiColumnCandidates(), false);
[kdValues, kdColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, '', defaultKdColumnCandidates(), false);
[leftPwmValues, leftPwmColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, '', defaultLeftPwmColumnCandidates(), false);
[rightPwmValues, rightPwmColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, '', defaultRightPwmColumnCandidates(), false);
[rawOutputValues, rawOutputColumnName] = extractFlexibleNumericColumn( ...
    tbl, names, '', defaultRawOutputColumnCandidates(), false);

timeS = ensureColumn(timeS);
currentHeadingRawDeg = ensureColumn(currentHeadingRawDeg);
expectedHeadingRawDeg = ensureColumn(expectedHeadingRawDeg);
if ~isempty(loggedHeadingErrorDeg)
    loggedHeadingErrorDeg = ensureColumn(loggedHeadingErrorDeg);
end
if ~isempty(kpValues)
    kpValues = ensureColumn(kpValues);
end
if ~isempty(kiValues)
    kiValues = ensureColumn(kiValues);
end
if ~isempty(kdValues)
    kdValues = ensureColumn(kdValues);
end
if ~isempty(leftPwmValues)
    leftPwmValues = ensureColumn(leftPwmValues);
end
if ~isempty(rightPwmValues)
    rightPwmValues = ensureColumn(rightPwmValues);
end
if ~isempty(rawOutputValues)
    rawOutputValues = ensureColumn(rawOutputValues);
end

validMask = isfinite(timeS) & isfinite(currentHeadingRawDeg) & isfinite(expectedHeadingRawDeg);
timeS = timeS(validMask);
currentHeadingRawDeg = currentHeadingRawDeg(validMask);
expectedHeadingRawDeg = expectedHeadingRawDeg(validMask);
loggedHeadingErrorDeg = cropOptional(loggedHeadingErrorDeg, validMask);
kpValues = cropOptional(kpValues, validMask);
kiValues = cropOptional(kiValues, validMask);
kdValues = cropOptional(kdValues, validMask);
leftPwmValues = cropOptional(leftPwmValues, validMask);
rightPwmValues = cropOptional(rightPwmValues, validMask);
rawOutputValues = cropOptional(rawOutputValues, validMask);

if isempty(timeS)
    error('文件中没有可用的时间/航向角有效数据：%s', filePath);
end

[timeS, order] = sort(timeS);
currentHeadingRawDeg = currentHeadingRawDeg(order);
expectedHeadingRawDeg = expectedHeadingRawDeg(order);
loggedHeadingErrorDeg = cropOptionalByIndex(loggedHeadingErrorDeg, order);
kpValues = cropOptionalByIndex(kpValues, order);
kiValues = cropOptionalByIndex(kiValues, order);
kdValues = cropOptionalByIndex(kdValues, order);
leftPwmValues = cropOptionalByIndex(leftPwmValues, order);
rightPwmValues = cropOptionalByIndex(rightPwmValues, order);
rawOutputValues = cropOptionalByIndex(rawOutputValues, order);

[timeS, uniqueIdx] = unique(timeS, 'stable');
currentHeadingRawDeg = currentHeadingRawDeg(uniqueIdx);
expectedHeadingRawDeg = expectedHeadingRawDeg(uniqueIdx);
loggedHeadingErrorDeg = cropOptionalByIndex(loggedHeadingErrorDeg, uniqueIdx);
kpValues = cropOptionalByIndex(kpValues, uniqueIdx);
kiValues = cropOptionalByIndex(kiValues, uniqueIdx);
kdValues = cropOptionalByIndex(kdValues, uniqueIdx);
leftPwmValues = cropOptionalByIndex(leftPwmValues, uniqueIdx);
rightPwmValues = cropOptionalByIndex(rightPwmValues, uniqueIdx);
rawOutputValues = cropOptionalByIndex(rawOutputValues, uniqueIdx);

if cfg.NormalizeTimeToZero
    timeS = timeS - timeS(1);
end

if cfg.UnwrapHeading
    currentHeadingDisplayDeg = unwrapDeg(currentHeadingRawDeg);
    expectedHeadingDisplayDeg = unwrapDeg(expectedHeadingRawDeg);
else
    currentHeadingDisplayDeg = currentHeadingRawDeg;
    expectedHeadingDisplayDeg = expectedHeadingRawDeg;
end

if ~isempty(loggedHeadingErrorDeg)
    headingErrorDeg = loggedHeadingErrorDeg;
    errorSource = 'csv_angle_error_deg';
else
    headingErrorDeg = angleDiffDeg(expectedHeadingRawDeg, currentHeadingRawDeg);
    errorSource = 'expected_minus_current';
end
metrics = computeErrorMetrics(headingErrorDeg);
pwmDiffValues = computePwmDiffValues(leftPwmValues, rightPwmValues);
trackingErrorDeg = angleDiffDeg(expectedHeadingRawDeg, currentHeadingRawDeg);
responseMetrics = computeResponseMetrics(timeS, trackingErrorDeg, expectedHeadingRawDeg, cfg);

[~, baseName] = fileparts(filePath);
controllerType = inferControllerType(filePath);
gains = extractControllerGains(kpValues, kiValues, kdValues);

data = struct();
data.filePath = filePath;
data.fileName = [baseName '.csv'];
data.baseName = baseName;
data.label = baseName;
data.columns = struct();
data.columns.time = timeColumnName;
data.columns.current_heading = currentColumnName;
data.columns.expected_heading = expectedColumnName;
data.columns.logged_error = loggedErrorColumnName;
data.columns.kp = kpColumnName;
data.columns.ki = kiColumnName;
data.columns.kd = kdColumnName;
data.columns.left_thruster_pwm = leftPwmColumnName;
data.columns.right_thruster_pwm = rightPwmColumnName;
data.columns.raw_output = rawOutputColumnName;
data.timeS = timeS;
data.currentHeadingDeg = currentHeadingDisplayDeg;
data.expectedHeadingDeg = expectedHeadingDisplayDeg;
data.currentHeadingRawDeg = currentHeadingRawDeg;
data.expectedHeadingRawDeg = expectedHeadingRawDeg;
data.headingErrorDeg = headingErrorDeg;
data.errorSource = errorSource;
data.controllerType = controllerType;
data.controllerGains = gains;
data.gainSeries = struct('kp', kpValues, 'ki', kiValues, 'kd', kdValues);
data.leftThrusterPwm = leftPwmValues;
data.rightThrusterPwm = rightPwmValues;
data.pwmDiff = pwmDiffValues;
data.rawOutput = rawOutputValues;
data.metrics = metrics;
data.responseMetrics = responseMetrics;
data.sampleCount = numel(timeS);
data.timeRangeS = [timeS(1), timeS(end)];
end

function figureFiles = plotSingleHeadingFigure(data, cfg)
figHeading = figure( ...
    'Name', sprintf('航向角曲线 - %s', data.baseName), ...
    'Color', 'w', ...
    'Visible', getFigureVisibility(cfg));

axHeading = axes('Parent', figHeading);
hold(axHeading, 'on');
plot(axHeading, data.timeS, data.currentHeadingDeg, '-', ...
    'Color', cfg.CurrentColor, ...
    'LineWidth', cfg.LineWidth, ...
    'DisplayName', '当前航向角');
plot(axHeading, data.timeS, data.expectedHeadingDeg, '--', ...
    'Color', cfg.ExpectedColor, ...
    'LineWidth', cfg.LineWidth, ...
    'DisplayName', '期望航向角');
applyAxesStyle(axHeading);
xlabel(axHeading, '时间 (s)');
ylabel(axHeading, '航向角 (°)');
applyFigureTitle(axHeading, '航向角跟踪曲线', buildControllerAnnotation(data), cfg);
legend(axHeading, 'Location', 'best', 'Interpreter', 'none');
applyChineseTextStyle(axHeading, cfg);
hold(axHeading, 'off');

baseName = sanitizeFileName(data.baseName);
figureFiles = struct();
figureFiles.heading = saveFigureBundle(figHeading, ...
    fullfile(cfg.RunOutputRoot, ['heading_tracking_' baseName]), cfg);
if hasPwmDiffSeries(data)
    figureFiles.pwm_diff = plotSinglePwmDiffFigure(data, cfg);
end
if hasGainSeries(data)
    figureFiles.gains = plotGainSeriesFigure(data, cfg);
end
end

function figureFiles = plotDualHeadingFigure(datasets, cfg)
figHeading = figure( ...
    'Name', '航向角对比', ...
    'Color', 'w', ...
    'Visible', getFigureVisibility(cfg));

currentColors = [cfg.CurrentColor; cfg.SecondRunColor];
mergeExpectedLegend = shouldMergeExpectedLegend(datasets);

axHeading = axes('Parent', figHeading);
hold(axHeading, 'on');
for i = 1:numel(datasets)
    baseColor = currentColors(i, :);
    controllerLabel = getControllerDisplayName(datasets(i).controllerType);
    if mergeExpectedLegend
        targetColor = cfg.ExpectedColor;
    else
        targetColor = lightenColor(baseColor, 0.35);
    end

    plot(axHeading, datasets(i).timeS, datasets(i).currentHeadingDeg, '-', ...
        'Color', baseColor, ...
        'LineWidth', cfg.LineWidth, ...
        'DisplayName', controllerLabel);
    if mergeExpectedLegend
        if i == 1
            plot(axHeading, datasets(i).timeS, datasets(i).expectedHeadingDeg, '--', ...
                'Color', targetColor, ...
                'LineWidth', cfg.LineWidth, ...
                'DisplayName', '期望航向角');
        else
            plot(axHeading, datasets(i).timeS, datasets(i).expectedHeadingDeg, '--', ...
                'Color', targetColor, ...
                'LineWidth', cfg.LineWidth, ...
                'HandleVisibility', 'off');
        end
    else
        plot(axHeading, datasets(i).timeS, datasets(i).expectedHeadingDeg, '--', ...
            'Color', targetColor, ...
            'LineWidth', cfg.LineWidth, ...
            'DisplayName', controllerLabel);
    end
end
applyAxesStyle(axHeading);
xlabel(axHeading, '时间 (s)');
ylabel(axHeading, '航向角 (°)');
applyFigureTitle(axHeading, '航向角对比', buildCompareAnnotation(datasets), cfg);
legend(axHeading, 'Location', 'best', 'Interpreter', 'none');
applyChineseTextStyle(axHeading, cfg);
hold(axHeading, 'off');

compareName = sprintf('%s_vs_%s', ...
    sanitizeFileName(datasets(1).baseName), ...
    sanitizeFileName(datasets(2).baseName));
figureFiles = struct();
figureFiles.heading = saveFigureBundle(figHeading, ...
    fullfile(cfg.RunOutputRoot, ['heading_tracking_compare_' compareName]), cfg);
if any(arrayfun(@hasPwmDiffSeries, datasets))
    figureFiles.pwm_diff = plotDualPwmDiffFigure(datasets, compareName, cfg);
end
end

function savedFigure = plotSinglePwmDiffFigure(data, cfg)
figPwm = figure( ...
    'Name', sprintf('PWM 差值 - %s', data.baseName), ...
    'Color', 'w', ...
    'Visible', getFigureVisibility(cfg));

ax = axes('Parent', figPwm);
hold(ax, 'on');
plot(ax, data.timeS, data.pwmDiff, '-', ...
    'Color', cfg.PwmDiffColor, ...
    'LineWidth', cfg.LineWidth, ...
    'DisplayName', 'PWM 差值');
yline(ax, 0, '--', ...
    'Color', cfg.ReferenceColor, ...
    'LineWidth', 1.0, ...
    'HandleVisibility', 'off');
applyAxesStyle(ax);
xlabel(ax, '时间 (s)');
ylabel(ax, '双桨 PWM 差值 (右桨 - 左桨)');
applyFigureTitle(ax, 'PWM 差值曲线', buildPwmFigureAnnotation(data), cfg);
legend(ax, 'Location', 'best', 'Interpreter', 'none');
applyChineseTextStyle(ax, cfg);
hold(ax, 'off');

baseName = sanitizeFileName(data.baseName);
savedFigure = saveFigureBundle(figPwm, ...
    fullfile(cfg.RunOutputRoot, ['pwm_diff_' baseName]), cfg);
end

function savedFigure = plotDualPwmDiffFigure(datasets, compareName, cfg)
figPwm = figure( ...
    'Name', 'PWM 差值对比', ...
    'Color', 'w', ...
    'Visible', getFigureVisibility(cfg));

ax = axes('Parent', figPwm);
hold(ax, 'on');
currentColors = [cfg.CurrentColor; cfg.SecondRunColor];
for i = 1:numel(datasets)
    if ~hasPwmDiffSeries(datasets(i))
        continue;
    end

    plot(ax, datasets(i).timeS, datasets(i).pwmDiff, '-', ...
        'Color', currentColors(i, :), ...
        'LineWidth', cfg.LineWidth, ...
        'DisplayName', getControllerDisplayName(datasets(i).controllerType));
end
yline(ax, 0, '--', ...
    'Color', cfg.ReferenceColor, ...
    'LineWidth', 1.0, ...
    'HandleVisibility', 'off');
applyAxesStyle(ax);
xlabel(ax, '时间 (s)');
ylabel(ax, '双桨 PWM 差值 (右桨 - 左桨)');
applyFigureTitle(ax, 'PWM 差值对比', buildComparePwmAnnotation(datasets), cfg);
legend(ax, 'Location', 'best', 'Interpreter', 'none');
applyChineseTextStyle(ax, cfg);
hold(ax, 'off');

savedFigure = saveFigureBundle(figPwm, ...
    fullfile(cfg.RunOutputRoot, ['pwm_diff_compare_' compareName]), cfg);
end

function savedFigure = plotGainSeriesFigure(data, cfg)
figGains = figure( ...
    'Name', sprintf('控制增益曲线 - %s', data.baseName), ...
    'Color', 'w', ...
    'Visible', getFigureVisibility(cfg));

ax = axes('Parent', figGains);
annotationText = buildGainFigureAnnotation(data);
hold(ax, 'on');

plotSingleGainLine(ax, data.timeS, data.gainSeries.kp, 'Kp', cfg.GainKpColor, cfg);
plotSingleGainLine(ax, data.timeS, data.gainSeries.ki, 'Ki', cfg.GainKiColor, cfg);
plotSingleGainLine(ax, data.timeS, data.gainSeries.kd, 'Kd', cfg.GainKdColor, cfg);

applyAxesStyle(ax);
xlabel(ax, '时间 (s)');
ylabel(ax, '增益值');
applyFigureTitle(ax, '控制增益随时间变化', annotationText, cfg);
legend(ax, 'Location', 'best', 'Interpreter', 'none');
applyChineseTextStyle(ax, cfg);
hold(ax, 'off');

baseName = sanitizeFileName(data.baseName);
savedFigure = saveFigureBundle(figGains, ...
    fullfile(cfg.RunOutputRoot, ['controller_gains_' baseName]), cfg);
end

function summaryFiles = saveSummaryArtifacts(results, cfg)
matPath = fullfile(cfg.RunOutputRoot, 'heading_tracking_results.mat');
txtPath = fullfile(cfg.RunOutputRoot, 'heading_tracking_summary.txt');
comparisonCsvPath = fullfile(cfg.RunOutputRoot, 'heading_tracking_comparison.csv');

save(matPath, 'results');

fid = fopen(txtPath, 'w');
if fid == -1
    error('无法写入结果摘要文件：%s', txtPath);
end

cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

fprintf(fid, '生成时间: %s\n', results.generated_at);
fprintf(fid, '发现模式: %s\n', results.discovery_mode);
fprintf(fid, '搜索根目录: %s\n', results.search_root);
fprintf(fid, '输出目录: %s\n', results.output_root);
fprintf(fid, '\n');

if isfield(results, 'comparison_summary') && isstruct(results.comparison_summary) && results.comparison_summary.available
    fprintf(fid, '航向角对比汇总表\n');
    fprintf(fid, 'ai_pid 文件: %s\n', results.comparison_summary.ai_pid_path);
    fprintf(fid, 'pid 文件: %s\n', results.comparison_summary.pid_path);
    fprintf(fid, '%s\n\n', buildComparisonSummaryText(results.comparison_summary));
    writeComparisonSummaryCsv(comparisonCsvPath, results.comparison_summary);
end

for i = 1:numel(results.runs)
    runData = results.runs(i);
    fprintf(fid, '[文件 %d]\n', i);
    fprintf(fid, '文件路径: %s\n', runData.filePath);
    fprintf(fid, '样本数: %d\n', runData.sampleCount);
    fprintf(fid, '时间列: %s\n', runData.columns.time);
    fprintf(fid, '当前航向角列: %s\n', runData.columns.current_heading);
    fprintf(fid, '期望航向角列: %s\n', runData.columns.expected_heading);
    fprintf(fid, '控制器类型: %s\n', runData.controllerType);
    fprintf(fid, '误差来源: %s\n', runData.errorSource);
    if ~isempty(runData.columns.logged_error)
        fprintf(fid, '日志误差列: %s\n', runData.columns.logged_error);
    end
    if ~isempty(runData.columns.left_thruster_pwm) && ~isempty(runData.columns.right_thruster_pwm)
        fprintf(fid, 'PWM 差值定义: %s - %s\n', ...
            runData.columns.right_thruster_pwm, runData.columns.left_thruster_pwm);
    end
    if ~isempty(runData.columns.raw_output)
        fprintf(fid, '原始控制输出列: %s\n', runData.columns.raw_output);
    end
    fprintf(fid, 'Kp: %s\n', formatNumericText(runData.controllerGains.kp));
    fprintf(fid, 'Ki: %s\n', formatNumericText(runData.controllerGains.ki));
    fprintf(fid, 'Kd: %s\n', formatNumericText(runData.controllerGains.kd));
    fprintf(fid, '时间范围 (s): %.6f -> %.6f\n', runData.timeRangeS(1), runData.timeRangeS(2));
    fprintf(fid, '均方根误差 (deg): %.9f\n', runData.metrics.rmse_deg);
    fprintf(fid, '平均绝对误差 (deg): %.9f\n', runData.metrics.mae_deg);
    fprintf(fid, '平均误差 (deg): %.9f\n', runData.metrics.mean_error_deg);
    fprintf(fid, '最大绝对误差 (deg): %.9f\n', runData.metrics.max_abs_error_deg);
    fprintf(fid, '上升时间 10%%->90%% (s): %s\n', formatNumericText(runData.responseMetrics.rise_time_s));
    fprintf(fid, '最大超调时间 (s): %s\n', formatNumericText(runData.responseMetrics.peak_time_s));
    fprintf(fid, '超调量 (deg): %s\n', formatNumericText(runData.responseMetrics.overshoot_deg));
    fprintf(fid, '超调量 (%%): %s\n', formatNumericText(runData.responseMetrics.overshoot_percent));
    fprintf(fid, '稳定时间/收敛时间 (s): %s\n', formatNumericText(runData.responseMetrics.settling_time_s));
    fprintf(fid, '稳定误差带 (deg): %s\n', formatNumericText(runData.responseMetrics.settling_band_deg));
    fprintf(fid, '稳态误差 (deg): %s\n', formatNumericText(runData.responseMetrics.steady_state_error_deg));
    fprintf(fid, '稳态平均绝对误差 (deg): %s\n', formatNumericText(runData.responseMetrics.steady_state_abs_error_deg));
    fprintf(fid, '\n');
end

writeFigureFiles(fid, results.figure_files, '');

summaryFiles = struct();
summaryFiles.mat = matPath;
summaryFiles.txt = txtPath;
if isfield(results, 'comparison_summary') && isstruct(results.comparison_summary) && results.comparison_summary.available
    summaryFiles.comparison_csv = comparisonCsvPath;
else
    summaryFiles.comparison_csv = '';
end
end

function comparisonSummary = buildComparisonSummary(datasets)
comparisonSummary = struct();
comparisonSummary.available = false;
comparisonSummary.ai_pid_index = [];
comparisonSummary.pid_index = [];
comparisonSummary.ai_pid_path = '';
comparisonSummary.pid_path = '';
comparisonSummary.note = '';
comparisonSummary.rows = struct([]);
comparisonSummary.table = table();

if numel(datasets) ~= 2
    return;
end

controllerTypes = {datasets.controllerType};
aiPidIdx = find(strcmp(controllerTypes, 'ai_pid'), 1, 'first');
pidIdx = find(strcmp(controllerTypes, 'ordinary_pid'), 1, 'first');
if isempty(aiPidIdx) || isempty(pidIdx)
    return;
end

specs = getComparisonMetricSpecs();
rowTemplate = struct( ...
    'metric', '', ...
    'unit', '', ...
    'ai_pid_value', NaN, ...
    'pid_value', NaN, ...
    'advantage_value', NaN, ...
    'ai_pid_text', '', ...
    'pid_text', '', ...
    'advantage_text', '');
rows = repmat(rowTemplate, numel(specs), 1);

for i = 1:numel(specs)
    aiPidValue = extractComparisonMetricValue(datasets(aiPidIdx), specs(i).key);
    pidValue = extractComparisonMetricValue(datasets(pidIdx), specs(i).key);
    advantageValue = computeAiPidAdvantage(specs(i).key, aiPidValue, pidValue);

    rows(i).metric = specs(i).label;
    rows(i).unit = specs(i).unit;
    rows(i).ai_pid_value = aiPidValue;
    rows(i).pid_value = pidValue;
    rows(i).advantage_value = advantageValue;
    rows(i).ai_pid_text = formatComparisonValue(aiPidValue);
    rows(i).pid_text = formatComparisonValue(pidValue);
    rows(i).advantage_text = formatComparisonValue(advantageValue);
end

comparisonSummary.available = true;
comparisonSummary.ai_pid_index = aiPidIdx;
comparisonSummary.pid_index = pidIdx;
comparisonSummary.ai_pid_path = datasets(aiPidIdx).filePath;
comparisonSummary.pid_path = datasets(pidIdx).filePath;
comparisonSummary.note = ['除“稳态误差”外，改善量按数值越小越好计算，即 pid - ai_pid；' ...
    '“稳态误差”按更接近 0 更好计算，即 abs(pid) - abs(ai_pid)。'];
comparisonSummary.rows = rows;
comparisonSummary.table = table( ...
    string({rows.metric}).', ...
    string({rows.unit}).', ...
    [rows.ai_pid_value].', ...
    [rows.pid_value].', ...
    [rows.advantage_value].', ...
    'VariableNames', {'Metric', 'Unit', 'AiPid', 'Pid', 'AiPidAdvantage'});
end

function specs = getComparisonMetricSpecs()
specs = [ ...
    struct('key', 'rmse_deg', 'label', '均方根误差', 'unit', 'deg'); ...
    struct('key', 'mae_deg', 'label', '平均绝对误差', 'unit', 'deg'); ...
    struct('key', 'max_abs_error_deg', 'label', '最大绝对误差', 'unit', 'deg'); ...
    struct('key', 'rise_time_s', 'label', '上升时间(10%-90%)', 'unit', 's'); ...
    struct('key', 'peak_time_s', 'label', '最大超调时间', 'unit', 's'); ...
    struct('key', 'overshoot_deg', 'label', '超调量', 'unit', 'deg'); ...
    struct('key', 'overshoot_percent', 'label', '超调百分比', 'unit', '%'); ...
    struct('key', 'settling_time_s', 'label', '稳定时间(收敛时间)', 'unit', 's'); ...
    struct('key', 'steady_state_error_deg', 'label', '稳态误差', 'unit', 'deg'); ...
    struct('key', 'steady_state_abs_error_deg', 'label', '稳态平均绝对误差', 'unit', 'deg')];
end

function value = extractComparisonMetricValue(runData, metricKey)
switch metricKey
    case 'rmse_deg'
        value = runData.metrics.rmse_deg;
    case 'mae_deg'
        value = runData.metrics.mae_deg;
    case 'max_abs_error_deg'
        value = runData.metrics.max_abs_error_deg;
    case 'rise_time_s'
        value = runData.responseMetrics.rise_time_s;
    case 'peak_time_s'
        value = runData.responseMetrics.peak_time_s;
    case 'overshoot_deg'
        value = runData.responseMetrics.overshoot_deg;
    case 'overshoot_percent'
        value = runData.responseMetrics.overshoot_percent;
    case 'settling_time_s'
        value = runData.responseMetrics.settling_time_s;
    case 'steady_state_error_deg'
        value = runData.responseMetrics.steady_state_error_deg;
    case 'steady_state_abs_error_deg'
        value = runData.responseMetrics.steady_state_abs_error_deg;
    otherwise
        error('未知的对比指标键：%s', metricKey);
end
end

function value = computeAiPidAdvantage(metricKey, aiPidValue, pidValue)
if ~(isnumeric(aiPidValue) && isscalar(aiPidValue) && isfinite(aiPidValue) && ...
        isnumeric(pidValue) && isscalar(pidValue) && isfinite(pidValue))
    value = NaN;
    return;
end

switch metricKey
    case 'steady_state_error_deg'
        value = abs(pidValue) - abs(aiPidValue);
    otherwise
        value = pidValue - aiPidValue;
end
end

function textValue = formatComparisonValue(value)
if isnumeric(value) && isscalar(value) && isfinite(value)
    textValue = sprintf('%.6f', value);
else
    textValue = 'N/A';
end
end

function textOut = buildComparisonSummaryText(comparisonSummary)
if ~isfield(comparisonSummary, 'available') || ~comparisonSummary.available || isempty(comparisonSummary.rows)
    textOut = '';
    return;
end

lines = cell(numel(comparisonSummary.rows) + 2, 1);
lines{1} = '指标	单位	ai_pid	pid	ai_pid相比pid改善量(正为更好)';
for i = 1:numel(comparisonSummary.rows)
    row = comparisonSummary.rows(i);
    lines{i + 1} = sprintf('%s\t%s\t%s\t%s\t%s', ...
        row.metric, row.unit, row.ai_pid_text, row.pid_text, row.advantage_text);
end
lines{end} = ['注：' comparisonSummary.note];
textOut = strjoin(lines, newline);
end

function writeComparisonSummaryCsv(csvPath, comparisonSummary)
fid = fopen(csvPath, 'w');
if fid == -1
    error('无法写入对比汇总 CSV：%s', csvPath);
end

cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

fprintf(fid, '指标,单位,ai_pid,pid,ai_pid相比pid改善量_正为更好\n');
for i = 1:numel(comparisonSummary.rows)
    row = comparisonSummary.rows(i);
    fprintf(fid, '%s,%s,%s,%s,%s\n', ...
        row.metric, row.unit, row.ai_pid_text, row.pid_text, row.advantage_text);
end
end

function writeFigureFiles(fid, figureFiles, prefix)
fieldNames = fieldnames(figureFiles);
for i = 1:numel(fieldNames)
    fieldName = fieldNames{i};
    fieldValue = figureFiles.(fieldName);
    if isstruct(fieldValue) && isfield(fieldValue, 'eps')
        if isempty(prefix)
            labelPrefix = fieldName;
        else
            labelPrefix = [prefix '_' fieldName];
        end
        if ~isempty(fieldValue.eps)
            fprintf(fid, '%s EPS 矢量图: %s\n', labelPrefix, fieldValue.eps);
        end
    elseif isstruct(fieldValue)
        if isempty(prefix)
            nextPrefix = fieldName;
        else
            nextPrefix = [prefix '_' fieldName];
        end
        writeFigureFiles(fid, fieldValue, nextPrefix);
    end
end
end

function tbl = safeReadTable(filePath, cfg)
try
    if isempty(cfg.Delimiter)
        tbl = readtable(filePath, 'TextType', 'string');
    else
        tbl = readtable(filePath, 'TextType', 'string', 'Delimiter', cfg.Delimiter);
    end
catch
    if isempty(cfg.Delimiter)
        tbl = readtable(filePath);
    else
        tbl = readtable(filePath, 'Delimiter', cfg.Delimiter);
    end
end
end

function [values, columnName] = extractFlexibleNumericColumn(tbl, normalizedNames, requestedColumn, defaultCandidates, required)
if nargin < 5
    required = true;
end

idx = [];
columnName = '';

if isnumeric(requestedColumn) && isscalar(requestedColumn) && isfinite(requestedColumn)
    idx = round(requestedColumn);
    if idx < 1 || idx > width(tbl)
        error('指定的列序号超出范围：%d', idx);
    end
    columnName = char(string(tbl.Properties.VariableNames{idx}));
elseif isTextSpecified(requestedColumn)
    requestedName = normalizeSingleName(requestedColumn);
    idx = find(strcmp(normalizedNames, requestedName), 1, 'first');
    if isempty(idx)
        error('找不到指定列：%s', char(string(requestedColumn)));
    end
    columnName = char(string(tbl.Properties.VariableNames{idx}));
else
    idx = findColumnIndex(normalizedNames, defaultCandidates);
    if isempty(idx)
        if required
            error('缺少必要列：%s', strjoin(defaultCandidates, ', '));
        else
            values = [];
            return;
        end
    end
    columnName = char(string(tbl.Properties.VariableNames{idx}));
end

values = tableColumnToNumeric(tbl{:, idx});
end

function metrics = computeErrorMetrics(errorDeg)
metrics = struct();
metrics.rmse_deg = sqrt(mean(errorDeg .^ 2));
metrics.mae_deg = mean(abs(errorDeg));
metrics.mean_error_deg = mean(errorDeg);
metrics.max_abs_error_deg = max(abs(errorDeg));
end

function pwmDiffValues = computePwmDiffValues(leftPwmValues, rightPwmValues)
if isempty(leftPwmValues) || isempty(rightPwmValues)
    pwmDiffValues = [];
    return;
end

pwmDiffValues = rightPwmValues - leftPwmValues;
end

function responseMetrics = computeResponseMetrics(timeS, trackingErrorDeg, expectedHeadingRawDeg, cfg)
responseMetrics = struct( ...
    'initial_error_deg', NaN, ...
    'step_amplitude_deg', NaN, ...
    'target_span_deg', NaN, ...
    'rise_time_s', NaN, ...
    'overshoot_deg', NaN, ...
    'overshoot_percent', NaN, ...
    'peak_time_s', NaN, ...
    'settling_time_s', NaN, ...
    'settling_band_deg', NaN, ...
    'steady_state_error_deg', NaN, ...
    'steady_state_abs_error_deg', NaN);

if isempty(timeS) || isempty(trackingErrorDeg)
    return;
end

validMask = isfinite(timeS) & isfinite(trackingErrorDeg);
if nargin >= 3 && ~isempty(expectedHeadingRawDeg)
    validMask = validMask & isfinite(expectedHeadingRawDeg);
end

timeS = timeS(validMask);
trackingErrorDeg = trackingErrorDeg(validMask);
expectedHeadingRawDeg = expectedHeadingRawDeg(validMask);
if isempty(timeS)
    return;
end

initialErrorDeg = trackingErrorDeg(1);
stepAmplitudeDeg = abs(initialErrorDeg);
responseMetrics.initial_error_deg = initialErrorDeg;
responseMetrics.step_amplitude_deg = stepAmplitudeDeg;
if ~isempty(expectedHeadingRawDeg)
    responseMetrics.target_span_deg = max(expectedHeadingRawDeg) - min(expectedHeadingRawDeg);
end

if ~(isfinite(stepAmplitudeDeg) && stepAmplitudeDeg > eps)
    return;
end

direction = sign(initialErrorDeg);
if direction == 0
    return;
end

absErrorDeg = abs(trackingErrorDeg);
riseStartIdx = find(absErrorDeg <= 0.90 * stepAmplitudeDeg, 1, 'first');
riseEndIdx = find(absErrorDeg <= 0.10 * stepAmplitudeDeg, 1, 'first');
if ~isempty(riseStartIdx) && ~isempty(riseEndIdx) && riseEndIdx >= riseStartIdx
    responseMetrics.rise_time_s = timeS(riseEndIdx) - timeS(riseStartIdx);
end

overshootSeries = max(0, -direction * trackingErrorDeg);
[overshootDeg, peakIndex] = max(overshootSeries);
responseMetrics.overshoot_deg = overshootDeg;
if isfinite(overshootDeg) && overshootDeg > 0
    responseMetrics.peak_time_s = timeS(peakIndex);
    responseMetrics.overshoot_percent = overshootDeg / stepAmplitudeDeg * 100;
end

settlingBandDeg = max(cfg.SettlingBandMinDeg, cfg.SettlingBandRatio * stepAmplitudeDeg);
responseMetrics.settling_band_deg = settlingBandDeg;
insideBand = abs(trackingErrorDeg) <= settlingBandDeg;
lastOutsideIdx = find(~insideBand, 1, 'last');
if isempty(lastOutsideIdx)
    responseMetrics.settling_time_s = timeS(1);
elseif lastOutsideIdx < numel(timeS)
    responseMetrics.settling_time_s = timeS(lastOutsideIdx + 1);
end

steadyStateStartIdx = [];
if isfinite(responseMetrics.settling_time_s)
    steadyStateStartIdx = find(timeS >= responseMetrics.settling_time_s, 1, 'first');
end
if isempty(steadyStateStartIdx)
    steadyStateStartIdx = max(1, ceil(0.9 * numel(timeS)));
end

steadyStateErrorDeg = trackingErrorDeg(steadyStateStartIdx:end);
steadyStateErrorDeg = steadyStateErrorDeg(isfinite(steadyStateErrorDeg));
if ~isempty(steadyStateErrorDeg)
    responseMetrics.steady_state_error_deg = mean(steadyStateErrorDeg);
    responseMetrics.steady_state_abs_error_deg = mean(abs(steadyStateErrorDeg));
end
end

function valuesOut = tableColumnToNumeric(valuesIn)
if iscell(valuesIn)
    valuesOut = str2double(valuesIn);
elseif isstring(valuesIn)
    valuesOut = str2double(valuesIn);
elseif ischar(valuesIn)
    valuesOut = str2double(cellstr(valuesIn));
elseif istable(valuesIn)
    valuesOut = table2array(valuesIn);
else
    valuesOut = valuesIn;
end
valuesOut = ensureColumn(valuesOut);
end

function values = ensureColumn(values)
values = values(:);
end

function values = cropOptional(values, mask)
if isempty(values)
    return;
end
values = values(mask);
end

function values = cropOptionalByIndex(values, indexList)
if isempty(values)
    return;
end
values = values(indexList);
end

function diffDeg = angleDiffDeg(currentDeg, expectedDeg)
diffDeg = mod(currentDeg - expectedDeg + 180, 360) - 180;
diffDeg = ensureColumn(diffDeg);
end

function valuesDeg = unwrapDeg(valuesDeg)
valuesDeg = rad2deg(unwrap(deg2rad(ensureColumn(valuesDeg))));
end

function [ax1, ax2] = createVerticalAxes(fig)
if exist('tiledlayout', 'file') == 2 || exist('tiledlayout', 'builtin') == 5
    layout = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    ax1 = nexttile(layout);
    ax2 = nexttile(layout);
else
    ax1 = subplot(2, 1, 1, 'Parent', fig);
    ax2 = subplot(2, 1, 2, 'Parent', fig);
end
end

function axesList = createStackedAxes(fig, axisCount)
axesList = gobjects(axisCount, 1);
if exist('tiledlayout', 'file') == 2 || exist('tiledlayout', 'builtin') == 5
    layout = tiledlayout(fig, axisCount, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    for i = 1:axisCount
        axesList(i) = nexttile(layout);
    end
else
    for i = 1:axisCount
        axesList(i) = subplot(axisCount, 1, i, 'Parent', fig);
    end
end
end

function applyAxesStyle(ax)
grid(ax, 'on');
box(ax, 'on');
set(ax, 'FontSize', 11, 'LineWidth', 0.9);
end

function applyChineseTextStyle(ax, cfg)
fontName = cfg.DisplayFontName;

set(ax, 'FontName', fontName);

if ~isempty(ax.Title) && isgraphics(ax.Title)
    set(ax.Title, 'FontName', fontName);
end
if ~isempty(ax.XLabel) && isgraphics(ax.XLabel)
    set(ax.XLabel, 'FontName', fontName);
end
if ~isempty(ax.YLabel) && isgraphics(ax.YLabel)
    set(ax.YLabel, 'FontName', fontName);
end

legendHandle = [];
if isprop(ax, 'Legend')
    legendHandle = ax.Legend;
end
if ~isempty(legendHandle) && isgraphics(legendHandle)
    set(legendHandle, 'FontName', fontName);
    set(legendHandle, 'Interpreter', 'none');
end
end

function applyFigureTitle(ax, mainTitle, annotationText, cfg)
% 按论文要求，图内不显示任何文字标题。
if nargin < 4
    cfg = struct(); %#ok<NASGU>
end
end

function annotationText = buildControllerAnnotation(data)
annotationText = '';
if ~strcmp(data.controllerType, 'ordinary_pid')
    return;
end

annotationText = sprintf('普通 PID 参数: Kp = %s, Ki = %s, Kd = %s', ...
    formatNumericText(data.controllerGains.kp), ...
    formatNumericText(data.controllerGains.ki), ...
    formatNumericText(data.controllerGains.kd));
end

function annotationText = buildCompareAnnotation(datasets)
parts = strings(0, 1);
for i = 1:numel(datasets)
    if ~strcmp(datasets(i).controllerType, 'ordinary_pid')
        continue;
    end
    parts(end + 1, 1) = string(sprintf('%s: Kp = %s, Ki = %s, Kd = %s', ...
        getControllerDisplayName(datasets(i).controllerType), ...
        formatNumericText(datasets(i).controllerGains.kp), ...
        formatNumericText(datasets(i).controllerGains.ki), ...
        formatNumericText(datasets(i).controllerGains.kd))); %#ok<AGROW>
end

if isempty(parts)
    annotationText = '';
else
    annotationText = char(strjoin(parts, ' | '));
end
end

function annotationText = buildPwmFigureAnnotation(data)
parts = strings(0, 1);
if ~isempty(data.columns.left_thruster_pwm) && ~isempty(data.columns.right_thruster_pwm)
    parts(end + 1, 1) = "PWM 差值 = " + string(data.columns.right_thruster_pwm) + ...
        " - " + string(data.columns.left_thruster_pwm); %#ok<AGROW>
end
if ~isempty(data.columns.raw_output)
    parts(end + 1, 1) = "raw output 列: " + string(data.columns.raw_output); %#ok<AGROW>
end

if isempty(parts)
    annotationText = '';
else
    annotationText = char(strjoin(parts, ' | '));
end
end

function annotationText = buildComparePwmAnnotation(datasets)
annotationText = '';
end

function annotationText = buildGainFigureAnnotation(data)
annotationText = '';
end

function plotSingleGainLine(ax, timeS, values, gainLabel, colorValue, cfg)
if ~hasFiniteSeries(values)
    return;
end

plot(ax, timeS, values, '-', ...
    'Color', colorValue, ...
    'LineWidth', cfg.LineWidth, ...
    'DisplayName', gainLabel);
end

function fieldName = buildSingleFigureFieldName(data, indexValue, usedFieldNames)
baseName = getControllerDisplayName(data.controllerType);
if strcmp(baseName, 'unknown')
    baseName = sprintf('single_%d', indexValue);
end

fieldName = matlab.lang.makeValidName(baseName);
if ~any(strcmp(usedFieldNames, fieldName))
    return;
end

fieldName = matlab.lang.makeValidName(sprintf('%s_%d', baseName, indexValue));
end

function controllerType = inferControllerType(filePath)
pathText = lower(strrep(char(string(filePath)), '/', '\'));
if contains(pathText, '\experiment_tests\ai_pid\')
    controllerType = 'ai_pid';
elseif contains(pathText, '\experiment_tests\pid\')
    controllerType = 'ordinary_pid';
else
    controllerType = 'unknown';
end
end

function tf = shouldMergeExpectedLegend(datasets)
tf = false;
if numel(datasets) ~= 2
    return;
end

firstValue = getFinalFiniteValue(datasets(1).expectedHeadingRawDeg);
secondValue = getFinalFiniteValue(datasets(2).expectedHeadingRawDeg);

if ~(isfinite(firstValue) && isfinite(secondValue))
    return;
end

tf = abs(angleDiffDeg(firstValue, secondValue)) < 1e-6;
end

function value = getFinalFiniteValue(values)
value = NaN;
if isempty(values)
    return;
end

values = values(isfinite(values));
if isempty(values)
    return;
end

value = values(end);
end

function tf = hasGainSeries(data)
tf = false;
if ~isfield(data, 'gainSeries')
    return;
end

tf = hasFiniteSeries(data.gainSeries.kp) || ...
    hasFiniteSeries(data.gainSeries.ki) || ...
    hasFiniteSeries(data.gainSeries.kd);
end

function tf = hasFiniteSeries(values)
tf = ~isempty(values) && any(isfinite(values));
end

function tf = hasPwmDiffSeries(data)
tf = isfield(data, 'pwmDiff') && hasFiniteSeries(data.pwmDiff);
end

function displayName = getControllerDisplayName(controllerType)
switch controllerType
    case 'ai_pid'
        displayName = 'ai_pid';
    case 'ordinary_pid'
        displayName = 'pid';
    otherwise
        displayName = 'unknown';
end
end

function gains = extractControllerGains(kpValues, kiValues, kdValues)
gains = struct();
gains.kp = summarizeGainValue(kpValues);
gains.ki = summarizeGainValue(kiValues);
gains.kd = summarizeGainValue(kdValues);
end

function value = summarizeGainValue(values)
if isempty(values)
    value = NaN;
    return;
end

values = values(isfinite(values));
if isempty(values)
    value = NaN;
else
    value = values(1);
end
end

function textValue = formatNumericText(value)
if isnumeric(value) && isscalar(value) && isfinite(value)
    textValue = sprintf('%.6g', value);
else
    textValue = 'N/A';
end
end

function fontName = getPreferredChineseFontName()
persistent cachedFontName
if ~isempty(cachedFontName)
    fontName = cachedFontName;
    return;
end
fontName = 'SimSun';
cachedFontName = fontName;
end

function figureFiles = saveFigureBundle(fig, basePath, cfg)
ensureFolder(fileparts(basePath));
figureFiles = struct('eps', '');
drawnow;

if cfg.SaveEpsFigures
    epsPath = [basePath '.eps'];
    exportgraphics(fig, epsPath, 'ContentType', 'vector');
    figureFiles.eps = epsPath;
end

if ~cfg.ShowFigures
    close(fig);
end
end

function ensureFolder(folderPath)
if ~isfolder(folderPath)
    mkdir(folderPath);
end
end

function [csvInputs, opts] = parseMainInputs(rawInputs, defaultCsvInputs)
opts = struct();
args = rawInputs;

if isempty(args)
    csvInputs = defaultCsvInputs;
    return;
end

if isstruct(args{end}) && isscalar(args{end})
    opts = args{end};
    args = args(1:end - 1);
end

if isempty(args)
    csvInputs = defaultCsvInputs;
elseif numel(args) == 1
    csvInputs = args{1};
else
    csvInputs = flattenInputArgs(args);
end
end

function flatInputs = flattenInputArgs(args)
flatInputs = {};
for i = 1:numel(args)
    item = args{i};
    if ischar(item) || (isstring(item) && isscalar(item))
        flatInputs{end + 1} = char(string(item)); %#ok<AGROW>
    elseif isstring(item)
        parts = cellstr(item(:));
        flatInputs = [flatInputs; parts]; %#ok<AGROW>
    elseif iscell(item)
        for j = 1:numel(item)
            if ~(ischar(item{j}) || isstring(item{j}))
                error('路径输入必须是文本。');
            end
            flatInputs{end + 1} = char(string(item{j})); %#ok<AGROW>
        end
    else
        error('路径输入必须是文本、字符串数组或元胞数组。');
    end
end
end

function inputItems = normalizeInputItems(csvInputs)
if isempty(csvInputs)
    inputItems = {};
    return;
end

if ischar(csvInputs) || (isstring(csvInputs) && isscalar(csvInputs))
    textValue = strtrim(char(string(csvInputs)));
    if isempty(textValue)
        inputItems = {};
    else
        inputItems = {textValue};
    end
    return;
end

if isstring(csvInputs)
    inputItems = cellstr(csvInputs(:));
    inputItems = inputItems(~cellfun(@isempty, inputItems));
    return;
end

if iscell(csvInputs)
    inputItems = csvInputs(:);
    for i = 1:numel(inputItems)
        if ~(ischar(inputItems{i}) || isstring(inputItems{i}))
            error('csvInputs 单元格中的每一项都必须是文本路径。');
        end
        inputItems{i} = strtrim(char(string(inputItems{i})));
    end
    inputItems = inputItems(~cellfun(@isempty, inputItems));
    return;
end

error('csvInputs 仅支持字符串、字符串数组或元胞数组。');
end

function resolvedPath = resolveInputPath(inputPath, scriptDir)
resolvedPath = char(string(inputPath));
if isempty(resolvedPath)
    return;
end

if isAbsolutePath(resolvedPath)
    return;
end

candidatePath = fullfile(scriptDir, resolvedPath);
if isfile(candidatePath) || isfolder(candidatePath)
    resolvedPath = candidatePath;
    return;
end

resolvedPath = fullfile(pwd, resolvedPath);
end

function tf = isAbsolutePath(pathText)
pathText = char(string(pathText));
tf = ~isempty(regexp(pathText, '^[A-Za-z]:[\\/]|^\\\\', 'once'));
end

function tf = hasMatchingColumn(normalizedNames, candidates)
tf = ~isempty(findColumnIndex(normalizedNames, candidates));
end

function idx = findColumnIndex(normalizedNames, candidates)
idx = [];
for i = 1:numel(candidates)
    idx = find(strcmp(normalizedNames, candidates{i}), 1, 'first');
    if ~isempty(idx)
        return;
    end
end
end

function candidates = buildCandidateList(requestedColumn, defaultCandidates)
candidates = defaultCandidates;
if ~isTextSpecified(requestedColumn)
    return;
end

requestedName = normalizeSingleName(requestedColumn);
if isempty(requestedName)
    return;
end

existingMask = strcmp(candidates, requestedName);
candidates = [{requestedName}, candidates(~existingMask)];
end

function tf = isTextSpecified(value)
if ischar(value)
    tf = ~isempty(strtrim(value));
elseif isstring(value) && isscalar(value)
    tf = strlength(strtrim(value)) > 0;
else
    tf = false;
end
end

function names = normalizeNames(variableNames)
names = strings(size(variableNames));
for i = 1:numel(variableNames)
    names(i) = string(normalizeSingleName(variableNames{i}));
end
names = cellstr(names);
end

function name = normalizeSingleName(variableName)
name = lower(char(string(variableName)));
name = regexprep(name, '[^a-z0-9]+', '_');
name = regexprep(name, '^_+|_+$', '');
end

function colorOut = lightenColor(colorIn, mixRatio)
mixRatio = max(0, min(1, mixRatio));
colorOut = colorIn + (1 - colorIn) * mixRatio;
end

function textOut = sanitizeFileName(textIn)
textOut = regexprep(char(string(textIn)), '[^A-Za-z0-9_-]+', '_');
textOut = regexprep(textOut, '_+', '_');
textOut = regexprep(textOut, '^_+|_+$', '');
if isempty(textOut)
    textOut = 'output';
end
end

function visibilityValue = getFigureVisibility(cfg)
if cfg.ShowFigures
    visibilityValue = 'on';
else
    visibilityValue = 'off';
end
end

function value = getOption(opts, fieldName, defaultValue)
if isstruct(opts) && isfield(opts, fieldName) && ~isempty(opts.(fieldName))
    value = opts.(fieldName);
else
    value = defaultValue;
end
end

function value = getNumericScalarOption(opts, fieldName, defaultValue)
value = getOption(opts, fieldName, defaultValue);
if ~(isnumeric(value) && isscalar(value) && isfinite(value))
    error('%s 必须是有限数值标量。', fieldName);
end
end

function pathValue = getPathOption(opts, fieldName, defaultValue, fallbackValue)
pathValue = getOption(opts, fieldName, fallbackValue);
if isempty(pathValue)
    pathValue = defaultValue;
end
pathValue = char(string(pathValue));
end

function modeText = parseReadMode(rawMode)
modeText = lower(strtrim(char(string(rawMode))));
switch modeText
    case {'ai_pid', 'ai'}
        modeText = 'ai_pid';
    case {'pid', 'ordinary_pid', 'classic_pid'}
        modeText = 'pid';
    case {'compare', 'both', 'dual'}
        modeText = 'compare';
    otherwise
        error('ReadMode 只支持 ai_pid / pid / compare。');
end
end

function folderPath = resolveFolderPath(folderPath, baseDir)
folderPath = char(string(folderPath));
if isempty(folderPath) || isAbsolutePath(folderPath)
    return;
end
folderPath = fullfile(baseDir, folderPath);
end

function candidates = defaultTimeColumnCandidates()
candidates = { ...
    'phase_elapsed_sec', ...
    'phase_elapsed_s', ...
    'elapsed_time_s', ...
    'elapsed_time', ...
    'elapsed_time_sec', ...
    'time_s', ...
    'time_sec', ...
    'time', ...
    'seconds', ...
    'timestamp', ...
    'timestamp_s', ...
    't'};
end

function candidates = defaultCurrentHeadingCandidates()
candidates = { ...
    'current_heading_deg', ...
    'heading_deg', ...
    'current_heading', ...
    'current_heading_angle_deg', ...
    'heading', ...
    'heading_angle', ...
    'heading_angle_deg', ...
    'yaw_deg', ...
    'psi_deg', ...
    'current_yaw_deg', ...
    'current_yaw', ...
    'ship_heading_deg', ...
    'yaw', ...
    'psi'};
end

function candidates = defaultExpectedHeadingCandidates()
candidates = { ...
    'final_control_angle_deg', ...
    'expected_heading_deg', ...
    'desired_heading_deg', ...
    'target_heading_deg', ...
    'setpoint_heading_deg', ...
    'command_heading_deg', ...
    'reference_heading_deg', ...
    'desired_heading_angle_deg', ...
    'expected_heading_angle_deg', ...
    'expect_heading_deg', ...
    'heading_cmd_deg', ...
    'heading_ref_deg', ...
    'heading_target_deg', ...
    'desired_yaw_deg', ...
    'target_yaw_deg', ...
    'expected_yaw_deg', ...
    'expected_psi_deg', ...
    'target_psi_deg', ...
    'yaw_setpoint_deg', ...
    'expected_heading', ...
    'desired_heading', ...
    'target_heading', ...
    'setpoint_heading', ...
    'command_heading', ...
    'reference_heading'};
end

function candidates = defaultErrorColumnCandidates()
candidates = { ...
    'angle_err_deg', ...
    'angle_error_deg', ...
    'heading_error_deg', ...
    'yaw_error_deg', ...
    'error_deg'};
end

function candidates = defaultKpColumnCandidates()
candidates = {'angle_kp', 'kp', 'heading_kp', 'yaw_kp'};
end

function candidates = defaultKiColumnCandidates()
candidates = {'angle_ki', 'ki', 'heading_ki', 'yaw_ki'};
end

function candidates = defaultKdColumnCandidates()
candidates = {'angle_kd', 'kd', 'heading_kd', 'yaw_kd'};
end

function candidates = defaultLeftPwmColumnCandidates()
candidates = {'left_thruster_pwm', 'left_pwm', 'port_thruster_pwm', 'port_pwm'};
end

function candidates = defaultRightPwmColumnCandidates()
candidates = {'right_thruster_pwm', 'right_pwm', 'starboard_thruster_pwm', 'starboard_pwm'};
end

function candidates = defaultRawOutputColumnCandidates()
candidates = {'raw_output', 'controller_output', 'control_output', 'pwm_diff_cmd', 'tau2_cmd'};
end

function timestampText = extractTimestampText(filePath)
token = regexp(filePath, '(\d{8}_\d{6})', 'tokens', 'once');
if isempty(token)
    timestampText = '';
else
    timestampText = token{1};
end
end
