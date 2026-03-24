function results = plot_ai_pid_heading_curves(csvInputs, opts)
%PLOT_AI_PID_HEADING_CURVES 绘制 AI PID 航向角曲线，并支持双 CSV 对比。
%
% 用法：
%   results = plot_ai_pid_heading_curves()
%   results = plot_ai_pid_heading_curves('experiment_tests')
%   results = plot_ai_pid_heading_curves('experiment_tests/run_a.csv')
%   results = plot_ai_pid_heading_curves({'run_a.csv', 'run_b.csv'})
%   results = plot_ai_pid_heading_curves(..., opts)
%
% 说明：
% 1. 不传输入时，默认先扫描 ai_pid/experiment_tests/**/*.csv；
%    如果没有找到可用 CSV，则回退到 ai_pid/origin_experiment_test/**/*.csv。
% 2. 自动模式只会选择最新的 1 个 CSV 文件。
% 3. 显式传入 2 个 CSV 文件时，会生成对比图和误差图。
% 4. CSV 至少需要包含：时间列、当前航向角列、期望航向角列。
%
% 常用可选项（opts）：
%   opts.OutputRoot            -> 结果输出目录，默认 ai_pid/results
%   opts.ShowFigures           -> true/false，是否显示图窗
%   opts.SaveMatFigures        -> true/false，是否额外保存 .fig
%   opts.NormalizeTimeToZero   -> true/false，是否让时间从 0 秒起
%   opts.UnwrapHeading         -> true/false，是否对航向角做展开显示
%   opts.Delimiter             -> CSV 分隔符，留空表示自动判断
%   opts.TimeColumn            -> 指定时间列名或列序号
%   opts.CurrentHeadingColumn  -> 指定当前航向角列名或列序号
%   opts.ExpectedHeadingColumn -> 指定期望航向角列名或列序号

    %% ======================== 输入配置区（可直接修改） ========================
    defaultCsvInputs = {};
    showFigures = true;
    saveMatFigures = false;
    normalizeTimeToZero = true;
    unwrapHeading = true;
    outputRoot = '';
    delimiter = '';
    timeColumn = '';
    currentHeadingColumn = '';
    expectedHeadingColumn = '';

    if nargin < 1
        csvInputs = defaultCsvInputs;
    end
    if nargin < 2 || isempty(opts)
        opts = struct();
    end

    scriptDir = fileparts(mfilename('fullpath'));
    cfg = buildConfig(scriptDir, opts, showFigures, saveMatFigures, ...
        normalizeTimeToZero, unwrapHeading, outputRoot, delimiter, ...
        timeColumn, currentHeadingColumn, expectedHeadingColumn);

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
        figureFiles = plotDualHeadingFigure(datasets, cfg);
    end

    results = struct();
    results.generated_at = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    results.discovery_mode = discoveryMode;
    results.search_root = resolvedSearchRoot;
    results.output_root = cfg.RunOutputRoot;
    results.selected_files = selectedFiles;
    results.runs = datasets;
    results.figure_files = figureFiles;
    results.summary_files = saveSummaryArtifacts(results, cfg);

    fprintf('\n航向角曲线结果汇总：\n');
    for i = 1:numel(datasets)
        fprintf('  [%d] %s\n', i, datasets(i).filePath);
        fprintf('      均方根误差 = %.6f deg\n', datasets(i).metrics.rmse_deg);
        fprintf('      平均绝对误差 = %.6f deg\n', datasets(i).metrics.mae_deg);
        fprintf('      最大绝对误差 = %.6f deg\n', datasets(i).metrics.max_abs_error_deg);
    end
    fprintf('  输出目录: %s\n', cfg.RunOutputRoot);
end

function cfg = buildConfig(scriptDir, opts, showFigures, saveMatFigures, ...
    normalizeTimeToZero, unwrapHeading, outputRoot, delimiter, ...
    timeColumn, currentHeadingColumn, expectedHeadingColumn)

cfg = struct();
cfg.ScriptDir = scriptDir;
cfg.ProjectRoot = scriptDir;
cfg.OutputRoot = getPathOption(opts, 'OutputRoot', fullfile(scriptDir, 'results'), outputRoot);
cfg.OutputRoot = resolveFolderPath(cfg.OutputRoot, scriptDir);
cfg.RunStamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
cfg.RunOutputRoot = fullfile(cfg.OutputRoot, ['run_' cfg.RunStamp]);
cfg.ShowFigures = logical(getOption(opts, 'ShowFigures', showFigures));
cfg.SaveMatFigures = logical(getOption(opts, 'SaveMatFigures', saveMatFigures));
cfg.NormalizeTimeToZero = logical(getOption(opts, 'NormalizeTimeToZero', normalizeTimeToZero));
cfg.UnwrapHeading = logical(getOption(opts, 'UnwrapHeading', unwrapHeading));
cfg.Delimiter = strtrim(char(string(getOption(opts, 'Delimiter', delimiter))));
cfg.TimeColumn = getOption(opts, 'TimeColumn', timeColumn);
cfg.CurrentHeadingColumn = getOption(opts, 'CurrentHeadingColumn', currentHeadingColumn);
cfg.ExpectedHeadingColumn = getOption(opts, 'ExpectedHeadingColumn', expectedHeadingColumn);
cfg.MaxFileCount = 2;
cfg.LineWidth = 1.4;
cfg.CurrentColor = [0.10, 0.35, 0.78];
cfg.ExpectedColor = [0.88, 0.33, 0.12];
cfg.ErrorColor = [0.14, 0.56, 0.36];
cfg.SecondRunColor = [0.60, 0.24, 0.68];
cfg.ReferenceColor = [0.35, 0.35, 0.35];
end

function [selectedFiles, resolvedSearchRoot, discoveryMode] = resolveInputFiles(csvInputs, cfg)
selectedFiles = struct([]);
resolvedSearchRoot = '';
discoveryMode = '';

inputItems = normalizeInputItems(csvInputs);
if isempty(inputItems)
    [catalog, resolvedSearchRoot] = discoverDefaultCsvFiles(cfg);
    if isempty(catalog)
        error(['未在 ai_pid/experiment_tests 或 ai_pid/origin_experiment_test 中找到可用 CSV。' ...
            '请检查文件夹，或显式传入 CSV 文件路径。']);
    end
    selectedFiles = selectLatestCsvFiles(catalog, 1);
    discoveryMode = 'default_latest';
    return;
end

if numel(inputItems) > cfg.MaxFileCount
    error('最多只支持 2 个 CSV 文件输入。');
end

if numel(inputItems) == 1
    resolvedPath = resolveInputPath(inputItems{1}, cfg.ScriptDir);
    if isfolder(resolvedPath)
        catalog = collectHeadingCsvFiles(resolvedPath, cfg);
        if isempty(catalog)
            error('在文件夹中没有发现包含时间/当前航向角/期望航向角列的 CSV：%s', resolvedPath);
        end
        selectedFiles = selectLatestCsvFiles(catalog, 1);
        resolvedSearchRoot = resolvedPath;
        discoveryMode = 'folder_latest';
        return;
    end
end

for i = 1:numel(inputItems)
    resolvedPath = resolveInputPath(inputItems{i}, cfg.ScriptDir);
    if isfolder(resolvedPath)
        error('传入多个输入项时，每一项都必须是 CSV 文件，当前是文件夹：%s', resolvedPath);
    end
    if ~isfile(resolvedPath)
        error('找不到 CSV 文件：%s', resolvedPath);
    end

    dirEntry = dir(resolvedPath);
    meta = inspectHeadingCsv(resolvedPath, dirEntry, cfg);
    if isempty(meta)
        error('CSV 缺少必要列，至少需要时间列、当前航向角列、期望航向角列：%s', resolvedPath);
    end

    if isempty(selectedFiles)
        selectedFiles = meta;
    else
        selectedFiles(end + 1) = meta; %#ok<AGROW>
    end
end

discoveryMode = 'explicit_files';
end

function [catalog, resolvedSearchRoot] = discoverDefaultCsvFiles(cfg)
catalog = struct([]);
resolvedSearchRoot = '';

experimentRoot = fullfile(cfg.ProjectRoot, 'experiment_tests');
originRoot = fullfile(cfg.ProjectRoot, 'origin_experiment_test');

experimentCatalog = collectHeadingCsvFiles(experimentRoot, cfg);
if ~isempty(experimentCatalog)
    catalog = experimentCatalog;
    resolvedSearchRoot = experimentRoot;
    return;
end

fprintf('未在 experiment_tests 中找到可用 CSV，回退到 origin_experiment_test。\n');

originCatalog = collectHeadingCsvFiles(originRoot, cfg);
if ~isempty(originCatalog)
    catalog = originCatalog;
    resolvedSearchRoot = originRoot;
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

timeS = ensureColumn(timeS);
currentHeadingRawDeg = ensureColumn(currentHeadingRawDeg);
expectedHeadingRawDeg = ensureColumn(expectedHeadingRawDeg);

validMask = isfinite(timeS) & isfinite(currentHeadingRawDeg) & isfinite(expectedHeadingRawDeg);
timeS = timeS(validMask);
currentHeadingRawDeg = currentHeadingRawDeg(validMask);
expectedHeadingRawDeg = expectedHeadingRawDeg(validMask);

if isempty(timeS)
    error('文件中没有可用的时间/航向角有效数据：%s', filePath);
end

[timeS, order] = sort(timeS);
currentHeadingRawDeg = currentHeadingRawDeg(order);
expectedHeadingRawDeg = expectedHeadingRawDeg(order);

[timeS, uniqueIdx] = unique(timeS, 'stable');
currentHeadingRawDeg = currentHeadingRawDeg(uniqueIdx);
expectedHeadingRawDeg = expectedHeadingRawDeg(uniqueIdx);

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

headingErrorDeg = angleDiffDeg(currentHeadingRawDeg, expectedHeadingRawDeg);
metrics = computeErrorMetrics(headingErrorDeg);

[~, baseName] = fileparts(filePath);

data = struct();
data.filePath = filePath;
data.fileName = [baseName '.csv'];
data.baseName = baseName;
data.label = baseName;
data.columns = struct();
data.columns.time = timeColumnName;
data.columns.current_heading = currentColumnName;
data.columns.expected_heading = expectedColumnName;
data.timeS = timeS;
data.currentHeadingDeg = currentHeadingDisplayDeg;
data.expectedHeadingDeg = expectedHeadingDisplayDeg;
data.currentHeadingRawDeg = currentHeadingRawDeg;
data.expectedHeadingRawDeg = expectedHeadingRawDeg;
data.headingErrorDeg = headingErrorDeg;
data.metrics = metrics;
data.sampleCount = numel(timeS);
data.timeRangeS = [timeS(1), timeS(end)];
end

function figureFiles = plotSingleHeadingFigure(data, cfg)
fig = figure( ...
    'Name', sprintf('AI PID 航向角曲线 - %s', data.baseName), ...
    'Color', 'w', ...
    'Visible', getFigureVisibility(cfg));

[ax1, ax2] = createVerticalAxes(fig);

axes(ax1);
hold(ax1, 'on');
plot(ax1, data.timeS, data.currentHeadingDeg, '-', ...
    'Color', cfg.CurrentColor, ...
    'LineWidth', cfg.LineWidth, ...
    'DisplayName', '当前航向角');
plot(ax1, data.timeS, data.expectedHeadingDeg, '--', ...
    'Color', cfg.ExpectedColor, ...
    'LineWidth', cfg.LineWidth, ...
    'DisplayName', '期望航向角');
applyAxesStyle(ax1);
ylabel(ax1, '航向角 (deg)');
title(ax1, sprintf('航向角跟踪曲线: %s', data.baseName), 'Interpreter', 'none');
legend(ax1, 'Location', 'best');
hold(ax1, 'off');

axes(ax2);
hold(ax2, 'on');
plot(ax2, data.timeS, data.headingErrorDeg, '-', ...
    'Color', cfg.ErrorColor, ...
    'LineWidth', cfg.LineWidth, ...
    'DisplayName', '当前 - 期望');
yline(ax2, 0, '--', ...
    'Color', cfg.ReferenceColor, ...
    'LineWidth', 1.0, ...
    'HandleVisibility', 'off');
applyAxesStyle(ax2);
xlabel(ax2, '时间 (s)');
ylabel(ax2, '误差 (deg)');
title(ax2, sprintf('航向角误差: 均方根误差 = %.3f deg, 平均绝对误差 = %.3f deg', ...
    data.metrics.rmse_deg, data.metrics.mae_deg));
legend(ax2, 'Location', 'best');
hold(ax2, 'off');

basePath = fullfile(cfg.RunOutputRoot, ['heading_tracking_' sanitizeFileName(data.baseName)]);
figureFiles = saveFigureBundle(fig, basePath, cfg);
end

function figureFiles = plotDualHeadingFigure(datasets, cfg)
fig = figure( ...
    'Name', 'AI PID 航向角对比', ...
    'Color', 'w', ...
    'Visible', getFigureVisibility(cfg));

[ax1, ax2] = createVerticalAxes(fig);
currentColors = [cfg.CurrentColor; cfg.SecondRunColor];

axes(ax1);
hold(ax1, 'on');
for i = 1:numel(datasets)
    baseColor = currentColors(i, :);
    targetColor = lightenColor(baseColor, 0.35);

    plot(ax1, datasets(i).timeS, datasets(i).currentHeadingDeg, '-', ...
        'Color', baseColor, ...
        'LineWidth', cfg.LineWidth, ...
        'DisplayName', sprintf('%s 当前', datasets(i).label));
    plot(ax1, datasets(i).timeS, datasets(i).expectedHeadingDeg, '--', ...
        'Color', targetColor, ...
        'LineWidth', cfg.LineWidth, ...
        'DisplayName', sprintf('%s 期望', datasets(i).label));
end
applyAxesStyle(ax1);
ylabel(ax1, '航向角 (deg)');
title(ax1, '双文件航向角对比', 'Interpreter', 'none');
legend(ax1, 'Location', 'best', 'Interpreter', 'none');
hold(ax1, 'off');

axes(ax2);
hold(ax2, 'on');
for i = 1:numel(datasets)
    plot(ax2, datasets(i).timeS, datasets(i).headingErrorDeg, '-', ...
        'Color', currentColors(i, :), ...
        'LineWidth', cfg.LineWidth, ...
        'DisplayName', sprintf('%s 误差', datasets(i).label));
end
yline(ax2, 0, '--', ...
    'Color', cfg.ReferenceColor, ...
    'LineWidth', 1.0, ...
    'HandleVisibility', 'off');
applyAxesStyle(ax2);
xlabel(ax2, '时间 (s)');
ylabel(ax2, '误差 (deg)');
title(ax2, '双文件航向角误差对比', 'Interpreter', 'none');
legend(ax2, 'Location', 'best', 'Interpreter', 'none');
hold(ax2, 'off');

compareName = sprintf('%s_vs_%s', ...
    sanitizeFileName(datasets(1).baseName), ...
    sanitizeFileName(datasets(2).baseName));
basePath = fullfile(cfg.RunOutputRoot, ['heading_tracking_compare_' compareName]);
figureFiles = saveFigureBundle(fig, basePath, cfg);
end

function summaryFiles = saveSummaryArtifacts(results, cfg)
matPath = fullfile(cfg.RunOutputRoot, 'heading_tracking_results.mat');
txtPath = fullfile(cfg.RunOutputRoot, 'heading_tracking_summary.txt');

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

for i = 1:numel(results.runs)
    runData = results.runs(i);
    fprintf(fid, '[文件 %d]\n', i);
    fprintf(fid, '文件路径: %s\n', runData.filePath);
    fprintf(fid, '样本数: %d\n', runData.sampleCount);
    fprintf(fid, '时间列: %s\n', runData.columns.time);
    fprintf(fid, '当前航向角列: %s\n', runData.columns.current_heading);
    fprintf(fid, '期望航向角列: %s\n', runData.columns.expected_heading);
    fprintf(fid, '时间范围 (s): %.6f -> %.6f\n', runData.timeRangeS(1), runData.timeRangeS(2));
    fprintf(fid, '均方根误差 (deg): %.9f\n', runData.metrics.rmse_deg);
    fprintf(fid, '平均绝对误差 (deg): %.9f\n', runData.metrics.mae_deg);
    fprintf(fid, '平均误差 (deg): %.9f\n', runData.metrics.mean_error_deg);
    fprintf(fid, '最大绝对误差 (deg): %.9f\n', runData.metrics.max_abs_error_deg);
    fprintf(fid, '\n');
end

fprintf(fid, 'PNG 图片: %s\n', results.figure_files.png);
if isfield(results.figure_files, 'fig') && ~isempty(results.figure_files.fig)
    fprintf(fid, 'MATLAB 图窗文件 FIG: %s\n', results.figure_files.fig);
end

summaryFiles = struct();
summaryFiles.mat = matPath;
summaryFiles.txt = txtPath;
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

function applyAxesStyle(ax)
grid(ax, 'on');
box(ax, 'on');
set(ax, 'FontName', 'Times New Roman', 'FontSize', 11, 'LineWidth', 0.9);
end

function figureFiles = saveFigureBundle(fig, basePath, cfg)
ensureFolder(fileparts(basePath));

pngPath = [basePath '.png'];
if exist('exportgraphics', 'file') == 2 || exist('exportgraphics', 'builtin') == 5
    exportgraphics(fig, pngPath, 'Resolution', 180);
else
    saveas(fig, pngPath);
end

figureFiles = struct();
figureFiles.png = pngPath;

if cfg.SaveMatFigures
    figPath = [basePath '.fig'];
    savefig(fig, figPath);
    figureFiles.fig = figPath;
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

function pathValue = getPathOption(opts, fieldName, defaultValue, fallbackValue)
pathValue = getOption(opts, fieldName, fallbackValue);
if isempty(pathValue)
    pathValue = defaultValue;
end
pathValue = char(string(pathValue));
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

function timestampText = extractTimestampText(filePath)
token = regexp(filePath, '(\d{8}_\d{6})', 'tokens', 'once');
if isempty(token)
    timestampText = '';
else
    timestampText = token{1};
end
end
