function results = identify_nomoto_stages(experimentRoot, opts)
% ======================== 输入配置区（可直接修改） ========================
%
% 运行模式：
% 'identify' -> 完整辨识（stage1 ~ stage4）
% 'validate' -> 只做 stage4 验证
% 'compare_validate' -> 单/双模型对比验证，只做 stage4，并额外叠加单模型 KT 曲线
runMode = 'identify';
%
% 是否启用角速度滤波：
% true  -> 先对 yaw_rate 做移动平均，再参与最小二乘拟合
% false -> 直接使用原始 yaw_rate 参与最小二乘拟合
useRateFilter = true;
%
% 是否显示图窗
showFigures = true;
%
% 是否额外保存 EPS 矢量图
saveEpsFigures = false;
%
% 输出目录。留空表示使用脚本同目录下的 results 文件夹
outputRoot = '';
%
% 直行修正所需的半 PWM 差值，逆时针为正
uTrim = 0;
%
% 角速度移动平均滤波窗口长度。越大越平滑，但边沿会更钝
rateFilterWindow = 7;
%
% stage1 稳态筛样参数。
% 1) 先去掉前面加速段：当 |r| 达到稳态中心值的该比例后，认为进入稳态
% 2) 再在后面保留落在稳态角速度范围内的样本
% 3) 最后按单次拟合残差剔除特别离谱的点
stage1SteadyEnterRatio = 0.85;
stage1SteadyRateTolDegS = 3.0;
stage1SteadyRateTolRatio = 0.15;
stage1ResidualTolDegS = 1.5;
stage1ResidualTolSigma = 3.0;
stage1SteadyMinSamples = 20;
stage1TailFraction = 0.30;
stage1TailMinSamples = 30;
%
% 有效输入阈值与导数边界裁剪样本数
minInputAbs = 1.0;
derivativeTrimSamples = 1;
%
% 是否允许联合回退辨识
enableJointFallback = true;
%
% 验证模式参数（仅 runMode = 'validate' 时生效）：
validateKPos = 0.00615955;
validateKNeg = 0.00705955;
validateT = 0.465642;
validateAlpha =  0.225721;
%
% 单/双模型对比验证参数（仅 runMode = 'compare_validate' 时生效）：
% 1. 双模型参数优先读取最新辨识缓存，也可通过 opts.KPos/KNeg/T/alpha 显式覆盖
% 2. 单模型默认按线性 KT 对比，因此 alpha 默认取 0
compareSingleK = NaN;
compareSingleT = NaN;
compareSingleAlpha = 0;
%
% 说明：
% 1. 默认数据目录：优先读取 Nomoto/experiment_tests
%    如果找不到完整阶段数据，会打印提示后回退到 origin_experiment_test
% 2. 直接点击运行时，会使用上面这组配置
% 3. 如果从命令行传入 experimentRoot / opts，则外部传入值优先

if nargin < 1
    experimentRoot = '';
end
if nargin < 2 || isempty(opts)
    opts = struct();
    opts.Mode = runMode;
    opts.EnableRateFilter = useRateFilter;
    opts.ShowFigures = showFigures;
    opts.SaveEpsFigures = saveEpsFigures;
    opts.RateFilterWindow = rateFilterWindow;
    opts.Stage1SteadyEnterRatio = stage1SteadyEnterRatio;
    opts.Stage1SteadyRateTolDegS = stage1SteadyRateTolDegS;
    opts.Stage1SteadyRateTolRatio = stage1SteadyRateTolRatio;
    opts.Stage1ResidualTolDegS = stage1ResidualTolDegS;
    opts.Stage1ResidualTolSigma = stage1ResidualTolSigma;
    opts.Stage1SteadyMinSamples = stage1SteadyMinSamples;
    opts.Stage1TailFraction = stage1TailFraction;
    opts.Stage1TailMinSamples = stage1TailMinSamples;
    opts.UTrim = uTrim;
    opts.MinInputAbs = minInputAbs;
    opts.DerivativeTrimSamples = derivativeTrimSamples;
    opts.EnableJointFallback = enableJointFallback;
    if ~isempty(outputRoot)
        opts.OutputRoot = outputRoot;
    end
    if isfinite(validateKPos)
        opts.KPos = validateKPos;
    end
    if isfinite(validateKNeg)
        opts.KNeg = validateKNeg;
    end
    if isfinite(validateT)
        opts.T = validateT;
    end
    if isfinite(validateAlpha)
        opts.alpha = validateAlpha;
    end
    if isfinite(compareSingleK)
        opts.SingleK = compareSingleK;
    end
    if isfinite(compareSingleT)
        opts.SingleT = compareSingleT;
    end
    if isfinite(compareSingleAlpha)
        opts.SingleAlpha = compareSingleAlpha;
    end
end

scriptDir = fileparts(mfilename('fullpath'));
cfg = buildConfig(scriptDir, experimentRoot, opts);
ensureFolder(cfg.OutputRoot);
ensureFolder(cfg.RunOutputRoot);
fprintf('===== 非线性 Nomoto 辨识试验与验证 =====\n');

[catalog, resolvedSearchRoot] = discoverStageCsvFiles(cfg);
if ~isempty(resolvedSearchRoot)
    cfg.SearchRoot = resolvedSearchRoot;
end
if isempty(catalog)
    error(['未找到可用于辨识的阶段 CSV 文件。' ...
        '请检查 experiment_tests 文件夹，或显式传入搜索路径。']);
end

requestedStageIds = getRequestedStageIds(cfg);
selectedFiles = selectLatestStageFiles(catalog, requestedStageIds, cfg);
if isempty(selectedFiles)
    error('没有选中 stage 1-4 的 CSV 文件，无法进行辨识。');
end

fprintf('本次选中的阶段文件如下：%s\n', newline);
for i = 1:numel(selectedFiles)
    fprintf('  阶段 %d -> %s\n', selectedFiles(i).stageId, selectedFiles(i).filePath);
end

compareParams = struct([]);
if isValidationMode(cfg)
    params = initializeValidationParams(cfg);
elseif isCompareValidationMode(cfg)
    cached = loadLatestCache(cfg.CacheFile, cfg.DefaultCacheFile);
    params = initializeParams(cfg, cached);
    compareParams = initializeCompareSingleParams(cfg);
else
    cached = loadLatestCache(cfg.CacheFile, cfg.DefaultCacheFile);
    params = initializeParams(cfg, cached);
end

results = struct();
results.generated_at = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
results.run_mode = cfg.Mode;
results.search_root = cfg.SearchRoot;
results.output_root = cfg.RunOutputRoot;
results.selected_files = struct([]);
results.stage_results = struct();
results.initial_params = paramsToStruct(params);
if isCompareValidationMode(cfg)
    results.compare_single_params = compareParamsToStruct(compareParams);
end

stageOrder = unique(sort([selectedFiles.stageId]));
writeIdx = 0;
for i = 1:numel(selectedFiles)
    writeIdx = writeIdx + 1;
    results.selected_files(writeIdx).stage_id = selectedFiles(i).stageId;
    results.selected_files(writeIdx).file_path = selectedFiles(i).filePath;
    results.selected_files(writeIdx).file_timestamp = selectedFiles(i).timestampLabel;
    if isfield(selectedFiles(i), 'pairedFilePath') && ~isempty(selectedFiles(i).pairedFilePath)
        writeIdx = writeIdx + 1;
        results.selected_files(writeIdx).stage_id = selectedFiles(i).stageId;
        results.selected_files(writeIdx).file_path = selectedFiles(i).pairedFilePath;
        results.selected_files(writeIdx).file_timestamp = selectedFiles(i).pairedTimestampLabel;
    end
end

for i = 1:numel(stageOrder)
    stageId = stageOrder(i);
    selected = selectedFiles([selectedFiles.stageId] == stageId);
    data = readStageData(selected.filePath, cfg);

    stageFolder = fullfile(cfg.RunOutputRoot, sprintf('stage%d', stageId));
    ensureFolder(stageFolder);

    hasPairedStage1 = stageId == 1 && isfield(selected, 'pairedFilePath') && ~isempty(selected.pairedFilePath);
    if isCompareValidationMode(cfg)
        overviewFiles = struct();
    else
        overviewFiles = plotCommonFigures(data, stageFolder, cfg, hasPairedStage1);
    end

    switch stageId
        case 1
            if isfield(selected, 'pairedFilePath') && ~isempty(selected.pairedFilePath)
                pairedData = readStageData(selected.pairedFilePath, cfg);
                stageResult = identifyStage1KDual(data, pairedData, stageFolder, cfg);
                gpsFigures = plotStage1DualGps(data, pairedData, stageFolder, cfg);
                overviewFiles.gps = gpsFigures.combined;
                overviewFiles.gps_pos = gpsFigures.positive_scatter;
                overviewFiles.gps_neg = gpsFigures.negative_scatter;
                overviewFiles.gps_circle_pos = gpsFigures.positive_circle;
                overviewFiles.gps_circle_neg = gpsFigures.negative_circle;
                stageResult.file_paths = {selected.filePath, selected.pairedFilePath};
                stageResult.stage_name = 'steady_turn_dual';
            else
                stageResult = identifyStage1K(data, stageFolder, cfg);
            end
            if isfinite(stageResult.K_pos)
                params.KPos = stageResult.K_pos;
                params.SourceKPos = 'stage1';
            end
            if isfinite(stageResult.K_neg)
                params.KNeg = stageResult.K_neg;
                params.SourceKNeg = 'stage1';
            end
        case 2
            [stageResult, params] = identifyStage2T(data, params, stageFolder, cfg);
        case 3
            [stageResult, params] = identifyStage3Alpha(data, params, stageFolder, cfg);
        case 4
            if isCompareValidationMode(cfg)
                stageResult = validateStage4Compare(data, params, compareParams, stageFolder, cfg);
            else
                stageResult = validateStage4(data, params, stageFolder, cfg);
            end
        otherwise
            error('暂不支持的 stage_id：%d', stageId);
    end

    stageResult.file_path = selected.filePath;
    if ~isfield(stageResult, 'stage_name') || isempty(stageResult.stage_name)
        stageResult.stage_name = data.stageName;
    end
    stageResult.common_figures = overviewFiles;
    results.stage_results.(sprintf('stage%d', stageId)) = stageResult;
    results.params_after_stage.(sprintf('stage%d', stageId)) = paramsToStruct(params); %#ok<STRNU>
end

results.final_params = paramsToStruct(params);
results.stage_order = stageOrder;
results.summary_files = saveSummaryArtifacts(results, cfg);

if isIdentifyMode(cfg)
    save(cfg.CacheFile, 'results');
end

if isCompareValidationMode(cfg)
    fprintf('\n单/双模型对比验证结果：\n');
    fprintf('  双模型 K+   = %.12g\n', results.final_params.K_pos);
    fprintf('  双模型 K-   = %.12g\n', results.final_params.K_neg);
    fprintf('  双模型 K_eq = %.12g\n', results.final_params.K);
    fprintf('  双模型 T    = %.12g\n', results.final_params.T);
    fprintf('  双模型 alpha = %.12g\n', results.final_params.alpha);
    fprintf('  单模型 K    = %.12g\n', results.compare_single_params.K);
    fprintf('  单模型 T    = %.12g\n', results.compare_single_params.T);
    fprintf('  单模型 alpha = %.12g\n', results.compare_single_params.alpha);
    if isfield(results.stage_results, 'stage4')
        stage4 = results.stage_results.stage4;
        fprintf('  双模型航向角 RMSE = %.4f deg\n', stage4.dual_model.heading_rmse_deg);
        fprintf('  单模型航向角 RMSE = %.4f deg\n', stage4.single_model.heading_rmse_deg);
        fprintf('  双模型辨识误差：[%.4f,%.4f] deg\n', ...
            stage4.dual_model.heading_error_min_deg, stage4.dual_model.heading_error_max_deg);
        fprintf('  单模型辨识误差：[%.4f,%.4f] deg\n', ...
            stage4.single_model.heading_error_min_deg, stage4.single_model.heading_error_max_deg);
    end
else
    fprintf('\n辨识结果汇总：\n');
    fprintf('  K+    = %.12g\n', results.final_params.K_pos);
    fprintf('  K-    = %.12g\n', results.final_params.K_neg);
    fprintf('  K_eq  = %.12g\n', results.final_params.K);
    fprintf('  T     = %.12g\n', results.final_params.T);
    fprintf('  alpha = %.12g\n', results.final_params.alpha);
    fprintf('  u_trim = %.12g\n', results.final_params.u_trim);
    if isfield(results.stage_results, 'stage1') && isfield(results.stage_results.stage1, 'turning_radius_m') ...
            && isfinite(results.stage_results.stage1.turning_radius_m)
        fprintf('  stage1 回转半径 ≈ %.3f m（直径 ≈ %.3f m）\n', ...
            results.stage_results.stage1.turning_radius_m, results.stage_results.stage1.turning_diameter_m);
        if isfield(results.stage_results.stage1, 'turning_radius_pos_m') && isfinite(results.stage_results.stage1.turning_radius_pos_m)
            fprintf('  stage1 正向回转半径 ≈ %.3f m\n', results.stage_results.stage1.turning_radius_pos_m);
        end
        if isfield(results.stage_results.stage1, 'turning_radius_neg_m') && isfinite(results.stage_results.stage1.turning_radius_neg_m)
            fprintf('  stage1 反向回转半径 ≈ %.3f m\n', results.stage_results.stage1.turning_radius_neg_m);
        end
    end
    if isfield(results.stage_results, 'stage4') ...
            && isfield(results.stage_results.stage4, 'heading_error_min_deg') ...
            && isfield(results.stage_results.stage4, 'heading_error_max_deg') ...
            && isfinite(results.stage_results.stage4.heading_error_min_deg) ...
            && isfinite(results.stage_results.stage4.heading_error_max_deg)
        fprintf('  辨识误差：[%.4f,%.4f] deg\n', ...
            results.stage_results.stage4.heading_error_min_deg, ...
            results.stage_results.stage4.heading_error_max_deg);
    end
end
fprintf('  输出目录: %s\n', cfg.RunOutputRoot);
end

function cfg = buildConfig(scriptDir, experimentRoot, opts)
cfg = struct();
cfg.ScriptDir = scriptDir;
cfg.ProjectRoot = fileparts(scriptDir);

if nargin < 2 || isempty(experimentRoot)
    cfg.UseExplicitSearchRoot = false;
    cfg.SearchRoot = cfg.ProjectRoot;
else
    cfg.UseExplicitSearchRoot = true;
    cfg.SearchRoot = char(string(experimentRoot));
end

if ~isfolder(cfg.SearchRoot)
    error('搜索根目录不存在：%s', cfg.SearchRoot);
end

cfg.OutputRoot = getOption(opts, 'OutputRoot', fullfile(scriptDir, 'results'));
cfg.OutputRoot = char(string(cfg.OutputRoot));
cfg.RunStamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
cfg.RunOutputRoot = fullfile(cfg.OutputRoot, ['run_' cfg.RunStamp]);
cfg.CacheFile = fullfile(cfg.OutputRoot, 'nomoto_latest_results.mat');
cfg.DefaultCacheFile = fullfile(scriptDir, 'results', 'nomoto_latest_results.mat');

% 常改 1：运行模式。'identify' 为完整辨识，'validate' 为只做 stage4 验证，
% 'compare_validate' 为单/双模型对比验证。
cfg.Mode = parseRunMode(getOption(opts, 'Mode', 'identify'));

% 常改 2：是否显示图窗。
cfg.ShowFigures = logical(getOption(opts, 'ShowFigures', true));
% 常改 3：是否额外保存 EPS 矢量图。
cfg.SaveEpsFigures = logical(getOption(opts, 'SaveEpsFigures', false));
% 常改 4：缺少前置参数时，是否允许联合回退辨识。
cfg.EnableJointFallback = logical(getOption(opts, 'EnableJointFallback', true));
% 常改 5：是否启用角速度移动平均滤波。
cfg.EnableRateFilter = logical(getOption(opts, 'EnableRateFilter', true));
% 常改 5：角速度滤波窗口。越大越平滑，但会更钝化边沿。
cfg.RateFilterWindow = max(1, round(getOption(opts, 'RateFilterWindow', 7)));
% 常改 6：stage1 稳态筛样参数；尾段取样仅在筛样失败时回退。
cfg.Stage1SteadyEnterRatio = getOption(opts, 'Stage1SteadyEnterRatio', 0.85);
cfg.Stage1SteadyRateTolDegS = getOption(opts, 'Stage1SteadyRateTolDegS', 3.0);
cfg.Stage1SteadyRateTolRatio = getOption(opts, 'Stage1SteadyRateTolRatio', 0.15);
cfg.Stage1ResidualTolDegS = getOption(opts, 'Stage1ResidualTolDegS', 1.5);
cfg.Stage1ResidualTolSigma = getOption(opts, 'Stage1ResidualTolSigma', 3.0);
cfg.Stage1SteadyMinSamples = max(5, round(getOption(opts, 'Stage1SteadyMinSamples', 20)));
cfg.Stage1TailFraction = getOption(opts, 'Stage1TailFraction', 0.30);
cfg.Stage1TailMinSamples = max(10, round(getOption(opts, 'Stage1TailMinSamples', 30)));
cfg.UTrim = getOption(opts, 'UTrim', 0.0);
% 常改 7：有效输入阈值与导数边界裁剪。
cfg.MinInputAbs = getOption(opts, 'MinInputAbs', 1.0);
cfg.DerivativeTrimSamples = max(0, round(getOption(opts, 'DerivativeTrimSamples', 1)));
cfg.LineWidth = 1.3;

% 验证模式常改 8：双模型直接在 opts 里填 KPos/KNeg/T/alpha。
cfg.OverrideK = getNumericOption(opts, 'K', NaN);
cfg.OverrideKPos = getNumericOptionAliases(opts, {'KPos', 'K_pos', 'KPlus', 'K_plus'}, NaN);
cfg.OverrideKNeg = getNumericOptionAliases(opts, {'KNeg', 'K_neg', 'KMinus', 'K_minus'}, NaN);
cfg.OverrideT = getNumericOption(opts, 'T', NaN);
cfg.OverrideAlpha = getNumericOption(opts, 'alpha', NaN);
cfg.CompareSingleK = getNumericOptionAliases(opts, {'SingleK', 'SingleModelK', 'CompareSingleK'}, NaN);
cfg.CompareSingleT = getNumericOptionAliases(opts, {'SingleT', 'SingleModelT', 'CompareSingleT'}, NaN);
cfg.CompareSingleAlpha = getNumericOptionAliases(opts, {'SingleAlpha', 'SingleModelAlpha', 'CompareSingleAlpha'}, 0.0);
end

function [catalog, resolvedSearchRoot] = discoverStageCsvFiles(cfg)
catalog = struct([]);
resolvedSearchRoot = '';

if cfg.UseExplicitSearchRoot
    catalog = collectStageCsvFiles(cfg.SearchRoot);
    resolvedSearchRoot = cfg.SearchRoot;
    return;
end

experimentRoot = fullfile(cfg.ProjectRoot, 'experiment_tests');
originRoot = fullfile(cfg.ProjectRoot, 'origin_experiment_test');

requiredStageIds = getRequestedStageIds(cfg);

experimentCatalog = collectStageCsvFiles(experimentRoot);
if hasRequiredStageSet(experimentCatalog, requiredStageIds)
    catalog = experimentCatalog;
    resolvedSearchRoot = experimentRoot;
    return;
end

fprintf('未在 experiment_tests 中找到当前模式所需的阶段 CSV，回退到 origin_experiment_test。\n');

originCatalog = collectStageCsvFiles(originRoot);
if ~isempty(originCatalog)
    catalog = originCatalog;
    resolvedSearchRoot = originRoot;
end
end

function catalog = collectStageCsvFiles(searchRoot)
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
    meta = inspectStageCsv(filePath, entries(i));
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

function tf = hasRequiredStageSet(catalog, stageIds)
if isempty(catalog)
    tf = false;
    return;
end

stages = unique([catalog.stageId]);
tf = all(ismember(stageIds, stages));
end

function meta = inspectStageCsv(filePath, dirEntry)
meta = struct([]);

try
    tbl = readStageTable(filePath, { ...
        {'elapsed_time_s', 'elapsed_time', 'time_s', 'time', 'timestamp'}, ...
        {'yaw_rate_deg_s', 'yaw_rate_degps', 'yaw_rate', 'r'}, ...
        {'left_pwm'}, ...
        {'right_pwm'}});
catch
    return;
end

names = normalizeNames(tbl.Properties.VariableNames);
requiredNames = {'elapsed_time_s', 'yaw_rate_deg_s', 'left_pwm', 'right_pwm'};
for i = 1:numel(requiredNames)
    if ~any(strcmp(names, requiredNames{i}))
        return;
    end
end

stageId = NaN;
if any(strcmp(names, 'stage_id'))
    stageValues = numericColumn(tbl, names, {'stage_id'}, true);
    stageValues = stageValues(isfinite(stageValues));
    if ~isempty(stageValues)
        stageId = round(mode(stageValues));
    end
end

if ~(isfinite(stageId) && any(stageId == 1:4))
    token = regexp(lower(filePath), 'stage([1-4])', 'tokens', 'once');
    if ~isempty(token)
        stageId = str2double(token{1});
    end
end

if ~(isfinite(stageId) && any(stageId == 1:4))
    return;
end

leftPwm = numericColumn(tbl, names, {'left_pwm'}, true);
rightPwm = numericColumn(tbl, names, {'right_pwm'}, true);
meanInput = mean(0.5 * (rightPwm - leftPwm), 'omitnan');

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
meta.stageId = stageId;
meta.filePath = filePath;
meta.fileName = dirEntry.name;
meta.timestampValue = timestampValue;
meta.timestampLabel = timestampLabel;
meta.meanInput = meanInput;
end

function selected = selectLatestStageFiles(catalog, stageIds, cfg)
if nargin < 2 || isempty(stageIds)
    stageIds = 1:4;
end

selected = struct([]);
for stageId = stageIds
    matches = catalog([catalog.stageId] == stageId);
    if isempty(matches)
        continue;
    end
    if stageId == 1 && isIdentifyMode(cfg)
        picked = selectStage1Pair(matches);
    else
        [~, idx] = max([matches.timestampValue]);
        picked = matches(idx);
    end
    if ~isfield(picked, 'pairedFilePath')
        picked.pairedFilePath = '';
        picked.pairedTimestampLabel = '';
        picked.pairedMeanInput = NaN;
    end
    if isempty(selected)
        selected = picked;
    else
        selected(end + 1) = picked; %#ok<AGROW>
    end
end
end

function picked = selectStage1Pair(matches)
posMask = arrayfun(@(s) isfield(s, 'meanInput') && isfinite(s.meanInput) && s.meanInput > 0, matches);
negMask = arrayfun(@(s) isfield(s, 'meanInput') && isfinite(s.meanInput) && s.meanInput < 0, matches);

if any(posMask) && any(negMask)
    posMatches = matches(posMask);
    negMatches = matches(negMask);
    [~, posIdx] = max([posMatches.timestampValue]);
    [~, negIdx] = max([negMatches.timestampValue]);
    picked = posMatches(posIdx);
    picked.pairedFilePath = negMatches(negIdx).filePath;
    picked.pairedTimestampLabel = negMatches(negIdx).timestampLabel;
    picked.pairedMeanInput = negMatches(negIdx).meanInput;
    fprintf('stage1 使用双定常回转：K+ 文件 -> %s\n', picked.filePath);
    fprintf('stage1 使用双定常回转：K- 文件 -> %s\n', picked.pairedFilePath);
elseif any(posMask) || any(negMask)
    available = matches(posMask | negMask);
    [~, idx] = max([available.timestampValue]);
    picked = available(idx);
    picked.pairedFilePath = '';
    picked.pairedTimestampLabel = '';
    picked.pairedMeanInput = NaN;
    fprintf('stage1 仅找到单边定常回转文件，另一侧 K 将在后续 zigzag 中联合辨识。\n');
else
    [~, idx] = max([matches.timestampValue]);
    picked = matches(idx);
    picked.pairedFilePath = '';
    picked.pairedTimestampLabel = '';
    picked.pairedMeanInput = NaN;
    fprintf('stage1 未识别出正负方向定常回转，退回单文件初值模式。\n');
end
end

function stageIds = getRequestedStageIds(cfg)
if isValidationMode(cfg) || isCompareValidationMode(cfg)
    stageIds = 4;
else
    stageIds = 1:4;
end
end

function tf = isIdentifyMode(cfg)
tf = strcmp(cfg.Mode, 'identify');
end

function tf = isValidationMode(cfg)
tf = strcmp(cfg.Mode, 'validate');
end

function tf = isCompareValidationMode(cfg)
tf = strcmp(cfg.Mode, 'compare_validate');
end

function data = readStageData(filePath, cfg)
tbl = readStageTable(filePath, { ...
    {'elapsed_time_s', 'elapsed_time', 'time_s', 'time', 'timestamp'}, ...
    {'yaw_rate_deg_s', 'yaw_rate_degps', 'yaw_rate', 'r'}, ...
    {'left_pwm'}, ...
    {'right_pwm'}});
names = normalizeNames(tbl.Properties.VariableNames);

timeS = numericColumn(tbl, names, {'elapsed_time_s', 'elapsed_time', 'time_s', 'time'}, true);
timestamp = numericColumn(tbl, names, {'timestamp'}, false);
if isempty(timeS)
    if isempty(timestamp)
        error('文件中未找到时间列：%s', filePath);
    end
    timeS = timestamp - timestamp(1);
end

leftPwm = numericColumn(tbl, names, {'left_pwm'}, true);
rightPwm = numericColumn(tbl, names, {'right_pwm'}, true);
yawRateDegS = numericColumn(tbl, names, {'yaw_rate_deg_s', 'yaw_rate_degps', 'yaw_rate', 'r'}, true);
headingDeg = numericColumn(tbl, names, {'heading_deg'}, false);
relativeHeadingDeg = numericColumn(tbl, names, {'relative_heading_deg'}, false);
accumTurnDeg = numericColumn(tbl, names, {'accumulated_turn_deg'}, false);
speedMps = numericColumn(tbl, names, {'speed_mps', 'speed'}, false);
longitude = numericColumn(tbl, names, {'longitude', 'lon'}, false);
latitude = numericColumn(tbl, names, {'latitude', 'lat'}, false);
stageIdCol = numericColumn(tbl, names, {'stage_id'}, false);
stageNameCol = textColumn(tbl, names, {'stage_name'}, false);

sampleCount = numel(timeS);
if isempty(stageNameCol)
    stageNameCol = strings(sampleCount, 1);
end

[timeS, order] = sort(columnVector(timeS));
leftPwm = reorderAndColumn(leftPwm, order);
rightPwm = reorderAndColumn(rightPwm, order);
yawRateDegS = reorderAndColumn(yawRateDegS, order);
headingDeg = reorderAndColumn(headingDeg, order);
relativeHeadingDeg = reorderAndColumn(relativeHeadingDeg, order);
accumTurnDeg = reorderAndColumn(accumTurnDeg, order);
speedMps = reorderAndColumn(speedMps, order);
longitude = reorderAndColumn(longitude, order);
latitude = reorderAndColumn(latitude, order);
stageIdCol = reorderAndColumn(stageIdCol, order);
stageNameCol = reorderAndColumn(stageNameCol, order);

validMask = isfinite(timeS) & isfinite(leftPwm) & isfinite(rightPwm) & isfinite(yawRateDegS);
timeS = timeS(validMask);
leftPwm = leftPwm(validMask);
rightPwm = rightPwm(validMask);
yawRateDegS = yawRateDegS(validMask);
headingDeg = cropOptional(headingDeg, validMask);
relativeHeadingDeg = cropOptional(relativeHeadingDeg, validMask);
accumTurnDeg = cropOptional(accumTurnDeg, validMask);
speedMps = cropOptional(speedMps, validMask);
longitude = cropOptional(longitude, validMask);
latitude = cropOptional(latitude, validMask);
stageIdCol = cropOptional(stageIdCol, validMask);
stageNameCol = cropOptional(stageNameCol, validMask);

[timeS, uniqueIdx] = unique(timeS, 'stable');
leftPwm = leftPwm(uniqueIdx);
rightPwm = rightPwm(uniqueIdx);
yawRateDegS = yawRateDegS(uniqueIdx);
headingDeg = cropOptionalByIndex(headingDeg, uniqueIdx);
relativeHeadingDeg = cropOptionalByIndex(relativeHeadingDeg, uniqueIdx);
accumTurnDeg = cropOptionalByIndex(accumTurnDeg, uniqueIdx);
speedMps = cropOptionalByIndex(speedMps, uniqueIdx);
longitude = cropOptionalByIndex(longitude, uniqueIdx);
latitude = cropOptionalByIndex(latitude, uniqueIdx);
stageIdCol = cropOptionalByIndex(stageIdCol, uniqueIdx);
stageNameCol = cropOptionalByIndex(stageNameCol, uniqueIdx);

if isempty(timeS)
    error('预处理后没有剩余有效样本：%s', filePath);
end

timeS = timeS - timeS(1);
uPwm = 0.5 * (rightPwm - leftPwm);
uPwm = columnVector(uPwm);
uModelPwm = uPwm - cfg.UTrim;

yawRateRadS = deg2rad(columnVector(yawRateDegS));
if cfg.EnableRateFilter
    yawRateRadSFiltered = movmean(yawRateRadS, cfg.RateFilterWindow, 'Endpoints', 'shrink');
else
    yawRateRadSFiltered = yawRateRadS;
end
if numel(timeS) >= 3
    yawAccelRadS2 = gradient(yawRateRadSFiltered, timeS);
else
    yawAccelRadS2 = zeros(size(yawRateRadSFiltered));
end

headingRelDeg = buildRelativeHeading(headingDeg, relativeHeadingDeg, accumTurnDeg, yawRateDegS, timeS);
headingAbsDeg = buildAbsoluteHeading(headingDeg);

analysisMask = true(size(timeS));
trim = min(cfg.DerivativeTrimSamples, floor((numel(timeS) - 1) / 2));
if trim > 0
    analysisMask(1:trim) = false;
    analysisMask(end - trim + 1:end) = false;
end
analysisMask = analysisMask & isfinite(yawAccelRadS2) & isfinite(yawRateRadSFiltered);
analysisMask = analysisMask & (abs(uModelPwm) >= cfg.MinInputAbs);

stageId = NaN;
if ~isempty(stageIdCol)
    finiteStage = stageIdCol(isfinite(stageIdCol));
    if ~isempty(finiteStage)
        stageId = round(mode(finiteStage));
    end
end
if ~(isfinite(stageId) && any(stageId == 1:4))
    token = regexp(lower(filePath), 'stage([1-4])', 'tokens', 'once');
    if ~isempty(token)
        stageId = str2double(token{1});
    end
end

if isempty(stageNameCol) || all(stageNameCol == "")
    stageName = sprintf('stage%d', stageId);
else
    stageName = char(stageNameCol(find(stageNameCol ~= "", 1, 'first')));
end

data = struct();
data.filePath = filePath;
data.stageId = stageId;
data.stageName = stageName;
data.timeS = columnVector(timeS);
data.leftPwm = columnVector(leftPwm);
data.rightPwm = columnVector(rightPwm);
data.uPwm = uPwm;
data.uModelPwm = uModelPwm;
data.uTrim = cfg.UTrim;
data.yawRateDegS = columnVector(yawRateDegS);
data.yawRateRadS = yawRateRadS;
data.yawRateRadSFiltered = yawRateRadSFiltered;
data.yawAccelRadS2 = columnVector(yawAccelRadS2);
data.headingRelDeg = columnVector(headingRelDeg);
data.headingAbsDeg = columnVector(headingAbsDeg);
data.speedMps = optionalColumn(speedMps, numel(timeS));
data.longitude = optionalColumn(longitude, numel(timeS));
data.latitude = optionalColumn(latitude, numel(timeS));
data.analysisMask = columnVector(analysisMask);
data.dtMedian = median(diff(timeS));
data.sampleCount = numel(timeS);
end

function tbl = readStageTable(filePath, requiredColumnGroups)
if nargin < 2
    requiredColumnGroups = {};
end

[tblDefault, defaultErr] = tryReadStageTable(filePath, '');
defaultOk = isempty(defaultErr) && hasRequiredColumnGroups(tblDefault, requiredColumnGroups);
if defaultOk
    tbl = tblDefault;
    return;
end

[tblUtf8, utf8Err] = tryReadStageTable(filePath, 'UTF-8');
utf8Ok = isempty(utf8Err) && hasRequiredColumnGroups(tblUtf8, requiredColumnGroups);
if utf8Ok
    fprintf('检测到默认读取异常，改用 UTF-8 重读：%s\n', filePath);
    tbl = tblUtf8;
    return;
end

if isempty(defaultErr)
    tbl = tblDefault;
    return;
end

if isempty(utf8Err)
    tbl = tblUtf8;
    return;
end

error('读取数据文件失败：%s\n默认读取失败：%s\nUTF-8 重读失败：%s', ...
    filePath, defaultErr.message, utf8Err.message);
end

function [tbl, readErr] = tryReadStageTable(filePath, encodingName)
tbl = table();
readErr = [];

try
    if strlength(string(encodingName)) == 0
        tbl = readtable(filePath, 'TextType', 'string');
    else
        tbl = readtable(filePath, 'TextType', 'string', 'Encoding', char(string(encodingName)));
    end
catch err
    readErr = err;
end
end

function tf = hasRequiredColumnGroups(tbl, requiredColumnGroups)
if isempty(requiredColumnGroups)
    tf = true;
    return;
end

if ~istable(tbl) || width(tbl) == 0
    tf = false;
    return;
end

names = normalizeNames(tbl.Properties.VariableNames);
tf = true;
for i = 1:numel(requiredColumnGroups)
    candidateNames = requiredColumnGroups{i};
    if ischar(candidateNames) || isstring(candidateNames)
        candidateNames = cellstr(string(candidateNames));
    end
    if ~any(ismember(names, normalizeNames(candidateNames)))
        tf = false;
        return;
    end
end
end

function overviewFiles = plotCommonFigures(data, stageFolder, cfg, skipGps)
style = plotStyle();
overviewFiles = struct();

if nargin < 4
    skipGps = false;
end

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
    'Name', sprintf('阶段%d总览', data.stageId));
tiledlayout(fig, 4, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plotDiscreteSeries(data.timeS, data.headingRelDeg, style.headingColor);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title(sprintf('阶段%d 航向角随时间变化', data.stageId));

nexttile;
plot(data.timeS, data.uPwm, 'Color', style.inputColor, 'LineWidth', cfg.LineWidth);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('半 PWM 差值');
title('半 PWM 差值随时间变化');

nexttile;
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
hold on;
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.2);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('角速度随时间变化');
legend({'实测值', '滤波值'}, 'Location', 'best');
hold off;

nexttile;
if any(isfinite(data.speedMps))
    plotDiscreteSeries(data.timeS, data.speedMps, style.speedColor);
    ylabel('线速度 (m/s)');
else
    plot(data.timeS, nan(size(data.timeS)), 'Color', style.speedColor, 'LineWidth', cfg.LineWidth);
    ylabel('线速度');
end
applyAxesStyle(style);
xlabel('时间 (s)');
title('线速度随时间变化');

overviewFiles.overview = saveFigureBundle(fig, fullfile(stageFolder, sprintf('stage%d_overview', data.stageId)), cfg);
overviewFiles.yaw_accel = struct('eps', '', 'fig', '');

if ~skipGps && all(isfinite(data.longitude)) && all(isfinite(data.latitude))
    figMap = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
        'Name', sprintf('阶段%d 轨迹散点图', data.stageId));
    scatter(data.longitude, data.latitude, 18, data.timeS, 'filled');
    hold on;
    scatter(data.longitude(1), data.latitude(1), 60, 'g', 'filled');
    scatter(data.longitude(end), data.latitude(end), 60, 'r', 'filled');
    applyAxesStyle(style);
    axis equal;
    xlabel('经度 (°E)');
    ylabel('纬度 (°N)');
    title(sprintf('阶段%d 经纬度散点图', data.stageId));
    c = colorbar;
    ylabel(c, '时间 (s)');
    legend({'轨迹', '起点', '终点'}, 'Location', 'best');
    hold off;
    overviewFiles.gps = saveFigureBundle(figMap, fullfile(stageFolder, sprintf('stage%d_gps', data.stageId)), cfg);
else
    overviewFiles.gps = struct('eps', '', 'fig', '');
end
end

function stageResult = identifyStage1K(data, stageFolder, cfg)
style = plotStyle();
posInfo = emptyStage1SteadyInfo();
negInfo = emptyStage1SteadyInfo();
hasPos = nnz(columnVector(data.analysisMask) & (columnVector(data.uModelPwm) > cfg.MinInputAbs)) >= 5;
hasNeg = nnz(columnVector(data.analysisMask) & (columnVector(data.uModelPwm) < -cfg.MinInputAbs)) >= 5;
if hasPos
    posInfo = selectStage1SteadySamples(data, cfg, 'positive');
end
if hasNeg
    negInfo = selectStage1SteadySamples(data, cfg, 'negative');
end

KPos = fitBranchGain(posInfo.uSel, posInfo.rSel);
KNeg = fitBranchGain(negInfo.uSel, negInfo.rSel);
gainSpec = struct('K_pos', KPos, 'K_neg', KNeg);

stageResult = struct();
stageResult.method = 'steady_rate_band_dual_branch_init';
stageResult.K_pos = KPos;
stageResult.K_neg = KNeg;
stageResult.K = equivalentBranchK(KPos, KNeg);
stageResult.asymmetry_ratio = safeBranchRatio(KNeg, KPos);
stageResult.sample_count = numel(posInfo.selectedIdx) + numel(negInfo.selectedIdx);
stageResult.tail_sample_count = stageResult.sample_count;
stageResult.mean_half_pwm = meanFinite([posInfo.uSel; negInfo.uSel]);
stageResult.mean_positive_half_pwm = meanFinite(posInfo.uSel);
stageResult.mean_negative_half_pwm = meanFinite(negInfo.uSel);
stageResult.branch_sample_count_pos = numel(posInfo.selectedIdx);
stageResult.branch_sample_count_neg = numel(negInfo.selectedIdx);
stageResult.mean_yaw_rate_deg_s = rad2deg(meanFinite([posInfo.rSel; negInfo.rSel]));
stageResult.steady_yaw_rate_hat_deg_s = rad2deg(meanFinite([KPos * posInfo.uSel; KNeg * negInfo.uSel]));
stageResult.mean_speed_mps = meanFinite([posInfo.speedSel; negInfo.speedSel]);
stageResult.turning_radius_m = estimateTurningRadius(stageResult.mean_speed_mps, meanFinite([posInfo.rSel; negInfo.rSel]));
stageResult.turning_diameter_m = 2 * stageResult.turning_radius_m;
stageResult.rmse_tail_rad_s = nomoto_utils.rmse( ...
    [posInfo.rSel; negInfo.rSel], ...
    [KPos * posInfo.uSel; KNeg * negInfo.uSel]);
stageResult.r2_tail = nomoto_utils.rsquared( ...
    [posInfo.rSel; negInfo.rSel], ...
    [KPos * posInfo.uSel; KNeg * negInfo.uSel]);
stageResult.selection_mode_pos = posInfo.mode;
stageResult.selection_mode_neg = negInfo.mode;
stageResult.steady_center_pos_deg_s = rad2deg(posInfo.rRef);
stageResult.steady_center_neg_deg_s = rad2deg(negInfo.rRef);
stageResult.residual_threshold_pos_deg_s = rad2deg(posInfo.residualTol);
stageResult.residual_threshold_neg_deg_s = rad2deg(negInfo.residualTol);
stageResult.residual_removed_count_pos = posInfo.residualRemovedCount;
stageResult.residual_removed_count_neg = negInfo.residualRemovedCount;

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段1-K辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
hMeasured = plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
hold on;
hFiltered = plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.1);
legendHandles = [hMeasured, hFiltered];
legendLabels = {'实测值', '滤波值'};
if ~isempty(posInfo.selectedIdx)
    hPos = scatter(data.timeS(posInfo.selectedIdx), rad2deg(data.yawRateRadSFiltered(posInfo.selectedIdx)), ...
        26, style.headingColor, 'filled', 'DisplayName', '正向筛选样本');
    legendHandles(end + 1) = hPos; %#ok<AGROW>
    legendLabels{end + 1} = '正向筛选样本'; %#ok<AGROW>
end
if ~isempty(negInfo.selectedIdx)
    hNeg = scatter(data.timeS(negInfo.selectedIdx), rad2deg(data.yawRateRadSFiltered(negInfo.selectedIdx)), ...
        26, style.pointColor, 'filled', 'DisplayName', '反向筛选样本');
    legendHandles(end + 1) = hNeg; %#ok<AGROW>
    legendLabels{end + 1} = '反向筛选样本'; %#ok<AGROW>
end
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('阶段1 双支路稳态范围筛选，K+ = %.6g，K- = %.6g', KPos, KNeg));
legend(legendHandles, legendLabels, 'Location', 'best');
hold off;

nexttile;
legendHandles = gobjects(0);
legendLabels = {};
hold on;
if ~isempty(posInfo.uSel)
    hPosFit = scatter(posInfo.uSel, rad2deg(posInfo.rSel), 24, style.headingColor, 'filled');
    legendHandles(end + 1) = hPosFit; %#ok<AGROW>
    legendLabels{end + 1} = '正向筛选样本'; %#ok<AGROW>
    xFitPos = buildFitAxis(posInfo.uSel);
    hFitPos = plot(xFitPos, rad2deg(KPos * xFitPos), '-', 'Color', style.fitColor, 'LineWidth', 1.3);
    legendHandles(end + 1) = hFitPos; %#ok<AGROW>
    legendLabels{end + 1} = 'r = K+ (u-u_{trim})'; %#ok<AGROW>
end
if ~isempty(negInfo.uSel)
    hNegFit = scatter(negInfo.uSel, rad2deg(negInfo.rSel), 24, style.pointColor, 'filled');
    legendHandles(end + 1) = hNegFit; %#ok<AGROW>
    legendLabels{end + 1} = '反向筛选样本'; %#ok<AGROW>
    xFitNeg = buildFitAxis(negInfo.uSel);
    hFitNeg = plot(xFitNeg, rad2deg(KNeg * xFitNeg), '--', 'Color', style.inputColor, 'LineWidth', 1.3);
    legendHandles(end + 1) = hFitNeg; %#ok<AGROW>
    legendLabels{end + 1} = 'r = K- (u-u_{trim})'; %#ok<AGROW>
end
applyAxesStyle(style);
xlabel('修正后半 PWM 差值');
ylabel('角速度 (deg/s)');
title('阶段1 双支路稳态样本与最小二乘拟合');
legend(legendHandles, legendLabels, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage1_identification_K'), cfg);
end

function stageResult = identifyStage1KDual(dataA, dataB, stageFolder, cfg)
style = plotStyle();

if mean(dataA.uModelPwm, 'omitnan') >= 0
    dataPos = dataA;
    dataNeg = dataB;
else
    dataPos = dataB;
    dataNeg = dataA;
end

[KPos, tailPos] = estimateStage1Branch(dataPos, cfg, 'positive');
[KNeg, tailNeg] = estimateStage1Branch(dataNeg, cfg, 'negative');

stageResult = struct();
stageResult.method = 'steady_rate_band_dual_files';
stageResult.K_pos = KPos;
stageResult.K_neg = KNeg;
stageResult.K = equivalentBranchK(KPos, KNeg);
stageResult.asymmetry_ratio = safeBranchRatio(KNeg, KPos);
stageResult.tail_sample_count_pos = numel(tailPos.selectedIdx);
stageResult.tail_sample_count_neg = numel(tailNeg.selectedIdx);
stageResult.mean_positive_half_pwm = mean(tailPos.uSel);
stageResult.mean_negative_half_pwm = mean(tailNeg.uSel);
stageResult.mean_yaw_rate_pos_deg_s = rad2deg(mean(tailPos.rSel));
stageResult.mean_yaw_rate_neg_deg_s = rad2deg(mean(tailNeg.rSel));
stageResult.mean_speed_pos_mps = meanFinite(tailPos.speedSel);
stageResult.mean_speed_neg_mps = meanFinite(tailNeg.speedSel);
stageResult.turning_radius_pos_m = estimateTurningRadius(stageResult.mean_speed_pos_mps, mean(tailPos.rSel));
stageResult.turning_radius_neg_m = estimateTurningRadius(stageResult.mean_speed_neg_mps, abs(mean(tailNeg.rSel)));
radiusValues = [stageResult.turning_radius_pos_m, stageResult.turning_radius_neg_m];
radiusValues = radiusValues(isfinite(radiusValues));
if isempty(radiusValues)
    stageResult.turning_radius_m = NaN;
else
    stageResult.turning_radius_m = mean(radiusValues);
end
stageResult.turning_diameter_m = 2 * stageResult.turning_radius_m;
stageResult.mean_speed_mps = meanFinite([stageResult.mean_speed_pos_mps; stageResult.mean_speed_neg_mps]);
stageResult.rmse_tail_rad_s = nomoto_utils.rmse([tailPos.rSel; tailNeg.rSel], [KPos * tailPos.uSel; KNeg * tailNeg.uSel]);
stageResult.r2_tail = nomoto_utils.rsquared([tailPos.rSel; tailNeg.rSel], [KPos * tailPos.uSel; KNeg * tailNeg.uSel]);
stageResult.selection_mode_pos = tailPos.mode;
stageResult.selection_mode_neg = tailNeg.mode;
stageResult.residual_threshold_pos_deg_s = rad2deg(tailPos.residualTol);
stageResult.residual_threshold_neg_deg_s = rad2deg(tailNeg.residualTol);
stageResult.residual_removed_count_pos = tailPos.residualRemovedCount;
stageResult.residual_removed_count_neg = tailNeg.residualRemovedCount;

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段1-双定常回转 K 辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
hMeasured = plotDiscreteSeries(dataPos.timeS, dataPos.yawRateDegS, style.measuredColor);
hold on;
hFiltered = plot(dataPos.timeS, rad2deg(dataPos.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.1);
hStart = xline(tailPos.startTime, '--', 'Color', style.referenceColor, 'LineWidth', 1.0, 'DisplayName', '进入稳态起点');
hCenter = yline(rad2deg(tailPos.rRef), '--', 'Color', style.inputColor, 'LineWidth', 1.0, 'DisplayName', '稳态角速度中心');
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('正向稳态范围筛选，K+ = %.6g', KPos));
legend([hMeasured, hFiltered, hStart, hCenter], ...
    {'实测值', '处理值', '进入稳态起点', '稳态角速度中心'}, 'Location', 'best');
hold off;

nexttile;
hMeasured = plotDiscreteSeries(dataNeg.timeS, dataNeg.yawRateDegS, style.measuredColor);
hold on;
hFiltered = plot(dataNeg.timeS, rad2deg(dataNeg.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.1);
hStart = xline(tailNeg.startTime, '--', 'Color', style.referenceColor, 'LineWidth', 1.0, 'DisplayName', '进入稳态起点');
hCenter = yline(rad2deg(tailNeg.rRef), '--', 'Color', style.inputColor, 'LineWidth', 1.0, 'DisplayName', '稳态角速度中心');
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('反向稳态范围筛选，K- = %.6g', KNeg));
legend([hMeasured, hFiltered, hStart, hCenter], ...
    {'实测值', '处理值', '进入稳态起点', '稳态角速度中心'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage1_identification_K_dual'), cfg);
end

function gpsFigure = plotStage1DualGps(dataA, dataB, stageFolder, cfg)
style = plotStyle();
gpsFigure = struct( ...
    'combined', struct('eps', '', 'fig', ''), ...
    'positive_scatter', struct('eps', '', 'fig', ''), ...
    'negative_scatter', struct('eps', '', 'fig', ''), ...
    'positive_circle', struct('eps', '', 'fig', ''), ...
    'negative_circle', struct('eps', '', 'fig', ''));

hasGpsA = all(isfinite(dataA.longitude)) && all(isfinite(dataA.latitude));
hasGpsB = all(isfinite(dataB.longitude)) && all(isfinite(dataB.latitude));
if ~(hasGpsA && hasGpsB)
    return;
end

allLon = [dataA.longitude; dataB.longitude];
allLat = [dataA.latitude; dataB.latitude];
lon0 = mean(allLon, 'omitnan');
lat0 = mean(allLat, 'omitnan');

    figMap = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
        'Name', sprintf('阶段%d 双定常回转轨迹散点图', dataA.stageId));
hold on;
scatter(dataA.longitude, dataA.latitude, 18, dataA.timeS, 'filled', 'DisplayName', '正向轨迹');
scatter(dataB.longitude, dataB.latitude, 18, dataB.timeS, 'filled', 'Marker', 'd', 'DisplayName', '反向轨迹');
scatter(dataA.longitude(1), dataA.latitude(1), 60, 'g', 'filled', 'HandleVisibility', 'off');
scatter(dataA.longitude(end), dataA.latitude(end), 60, 'r', 'filled', 'HandleVisibility', 'off');
scatter(dataB.longitude(1), dataB.latitude(1), 60, 'g', 'filled', 'Marker', 's', 'HandleVisibility', 'off');
scatter(dataB.longitude(end), dataB.latitude(end), 60, 'r', 'filled', 'Marker', 's', 'HandleVisibility', 'off');

    applyAxesStyle(style);
    axis equal;
    xlabel('经度 (°E)');
ylabel('纬度 (°N)');
title(sprintf('阶段%d 双定常回转轨迹散点图', dataA.stageId));
c = colorbar;
ylabel(c, '时间 (s)');
legend('Location', 'best');
hold off;

gpsFigure.combined = saveFigureBundle(figMap, fullfile(stageFolder, sprintf('stage%d_gps', dataA.stageId)), cfg);
gpsFigure.positive_scatter = plotSingleGpsScatterFigure( ...
    dataA, stageFolder, cfg, '正向', 'o', sprintf('stage%d_gps_pos', dataA.stageId));
gpsFigure.negative_scatter = plotSingleGpsScatterFigure( ...
    dataB, stageFolder, cfg, '反向', 'd', sprintf('stage%d_gps_neg', dataB.stageId));
gpsFigure.positive_circle = plotSingleTurningCircleFigure( ...
    dataA, lon0, lat0, stageFolder, cfg, '正向', style.headingColor, ...
    sprintf('stage%d_gps_pos_circle', dataA.stageId));
gpsFigure.negative_circle = plotSingleTurningCircleFigure( ...
    dataB, lon0, lat0, stageFolder, cfg, '反向', style.pointColor, ...
    sprintf('stage%d_gps_neg_circle', dataB.stageId));
end

function figureBundle = plotSingleGpsScatterFigure(data, stageFolder, cfg, branchLabel, markerSpec, fileTag)
style = plotStyle();
figureBundle = struct('eps', '', 'fig', '');

validMask = isfinite(data.longitude) & isfinite(data.latitude) & isfinite(data.timeS);
if nnz(validMask) < 2
    return;
end

lon = data.longitude(validMask);
lat = data.latitude(validMask);
timeS = data.timeS(validMask);

figMap = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
    'Name', sprintf('阶段%d %s定常回转轨迹散点图', data.stageId, branchLabel));
hold on;
scatter(lon, lat, 20, timeS, 'filled', 'Marker', markerSpec, 'DisplayName', [branchLabel '轨迹']);
scatter(lon(1), lat(1), 62, 'g', 'filled', 'Marker', 's', 'DisplayName', '起点');
scatter(lon(end), lat(end), 62, 'r', 'filled', 'Marker', 's', 'DisplayName', '终点');
applyAxesStyle(style);
axis equal;
xlabel('经度 (°E)');
ylabel('纬度 (°N)');
title(sprintf('阶段%d %s定常回转轨迹散点图', data.stageId, branchLabel));
c = colorbar;
ylabel(c, '时间 (s)');
legend('Location', 'best');
hold off;

figureBundle = saveFigureBundle(figMap, fullfile(stageFolder, fileTag), cfg);
end

function figureBundle = plotSingleTurningCircleFigure(data, lon0, lat0, stageFolder, cfg, branchLabel, colorSpec, fileTag)
style = plotStyle();
figureBundle = struct('eps', '', 'fig', '');

[xLocalM, yLocalM] = lonLatToLocalMeters(data.longitude, data.latitude, lon0, lat0);
validMask = isfinite(xLocalM) & isfinite(yLocalM);
xLocalM = xLocalM(validMask);
yLocalM = yLocalM(validMask);

if numel(xLocalM) < 3
    return;
end

tailIdx = buildCircleFitIndices(numel(xLocalM), cfg.Stage1TailFraction, cfg.Stage1TailMinSamples);
[centerX, centerY, radiusM, rmseM, isValid] = fitCircleLeastSquares(xLocalM(tailIdx), yLocalM(tailIdx));

figCircle = figure('Visible', figureVisibility(cfg), 'Color', 'w', ...
    'Name', sprintf('阶段%d %s回转圆拟合', data.stageId, branchLabel));
hold on;
plot(xLocalM, yLocalM, '-', 'Color', colorSpec, 'LineWidth', 1.0, 'DisplayName', [branchLabel '轨迹']);
scatter(xLocalM(tailIdx), yLocalM(tailIdx), 20, colorSpec, 'filled', ...
    'DisplayName', [branchLabel '尾段拟合点']);
scatter(xLocalM(1), yLocalM(1), 54, 'g', 'filled', 'DisplayName', '起点');
scatter(xLocalM(end), yLocalM(end), 54, 'r', 'filled', 'DisplayName', '终点');

if isValid
    theta = linspace(0, 2 * pi, 361);
    plot(centerX + radiusM * cos(theta), centerY + radiusM * sin(theta), '--', ...
        'Color', style.fitColor, 'LineWidth', 1.3, 'DisplayName', '拟合圆');
    scatter(centerX, centerY, 46, style.referenceColor, 'filled', 'DisplayName', '圆心');
end

applyAxesStyle(style);
axis equal;
xlabel('局部 X (m)');
ylabel('局部 Y (m)');
if isValid
    title(sprintf('阶段%d %s回转圆拟合，R = %.3f m，RMSE = %.3f m', ...
        data.stageId, branchLabel, radiusM, rmseM));
else
    title(sprintf('阶段%d %s回转圆拟合（圆拟合失败）', data.stageId, branchLabel));
end
legend('Location', 'best');
hold off;

figureBundle = saveFigureBundle(figCircle, fullfile(stageFolder, fileTag), cfg);
end

function [xLocalM, yLocalM] = lonLatToLocalMeters(longitude, latitude, lon0, lat0)
earthRadiusM = 6371000;
xLocalM = earthRadiusM * deg2rad(longitude - lon0) * cosd(lat0);
yLocalM = earthRadiusM * deg2rad(latitude - lat0);
end

function fitIdx = buildCircleFitIndices(sampleCount, tailFraction, minSamples)
tailCount = max(minSamples, ceil(sampleCount * tailFraction));
tailCount = min(tailCount, sampleCount);
fitIdx = (sampleCount - tailCount + 1:sampleCount).';
end

function [centerX, centerY, radiusM, rmseM, isValid] = fitCircleLeastSquares(x, y)
centerX = NaN;
centerY = NaN;
radiusM = NaN;
rmseM = NaN;
isValid = false;

x = columnVector(x);
y = columnVector(y);
if numel(x) < 3 || numel(y) < 3
    return;
end

A = [2 * x, 2 * y, ones(size(x))];
b = x .^ 2 + y .^ 2;
if rank(A) < 3
    return;
end

coeff = A \ b;
centerX = coeff(1);
centerY = coeff(2);
radiusSquared = coeff(3) + centerX ^ 2 + centerY ^ 2;
if ~(isfinite(radiusSquared) && radiusSquared > 0)
    centerX = NaN;
    centerY = NaN;
    return;
end

radiusM = sqrt(radiusSquared);
radialError = hypot(x - centerX, y - centerY) - radiusM;
rmseM = sqrt(mean(radialError .^ 2, 'omitnan'));
isValid = isfinite(centerX) && isfinite(centerY) && isfinite(radiusM);
end

function [K, tailInfo] = estimateStage1Branch(data, cfg, signMode)
tailInfo = selectStage1SteadySamples(data, cfg, signMode);
K = fitBranchGain(tailInfo.uSel, tailInfo.rSel);
if ~isfinite(K)
    error('stage1 稳态筛选后的输入过小，无法稳定辨识支路增益。');
end
end

function steadyInfo = emptyStage1SteadyInfo()
steadyInfo = struct( ...
    'mode', 'empty', ...
    'selectedIdx', zeros(0, 1), ...
    'startTime', NaN, ...
    'rRef', NaN, ...
    'rateTol', NaN, ...
    'residualTol', NaN, ...
    'residualRemovedCount', 0, ...
    'uSel', zeros(0, 1), ...
    'rSel', zeros(0, 1), ...
    'speedSel', zeros(0, 1));
end

function steadyInfo = selectStage1SteadySamples(data, cfg, signMode)
timeS = columnVector(data.timeS);
u = columnVector(data.uModelPwm);
r = columnVector(data.yawRateRadSFiltered);
speedMps = columnVector(data.speedMps);
baseMask = columnVector(data.analysisMask);
baseMask = baseMask & isfinite(timeS) & isfinite(u) & isfinite(r);

switch lower(string(signMode))
    case "positive"
        baseMask = baseMask & (u > cfg.MinInputAbs);
    case "negative"
        baseMask = baseMask & (u < -cfg.MinInputAbs);
    otherwise
        baseMask = baseMask & (abs(u) >= cfg.MinInputAbs);
end

validIdx = find(baseMask);
if numel(validIdx) < 5
    error('阶段1有效样本不足，无法稳定辨识 K。');
end

tailCount = max(cfg.Stage1TailMinSamples, ceil(cfg.Stage1TailFraction * numel(validIdx)));
tailCount = min(tailCount, numel(validIdx));
tailIdx = validIdx(end - tailCount + 1:end);
if isempty(tailIdx)
    error('阶段1无法获得稳态中心值。');
end

steadyInfo = emptyStage1SteadyInfo();
rRef = median(r(tailIdx), 'omitnan');
if ~(isfinite(rRef) && abs(rRef) > eps)
    rRef = mean(r(tailIdx), 'omitnan');
end
if ~(isfinite(rRef) && abs(rRef) > eps)
    rRef = median(r(validIdx), 'omitnan');
end
if ~(isfinite(rRef) && abs(rRef) > eps)
    error('阶段1无法得到有效的稳态角速度中心值。');
end

enterThreshold = cfg.Stage1SteadyEnterRatio * abs(rRef);
rateTol = max(deg2rad(cfg.Stage1SteadyRateTolDegS), cfg.Stage1SteadyRateTolRatio * abs(rRef));

enterIdx = validIdx(find(abs(r(validIdx)) >= enterThreshold, 1, 'first'));
if isempty(enterIdx)
    enterIdx = tailIdx(1);
end

selectedIdx = validIdx(validIdx >= enterIdx & abs(r(validIdx) - rRef) <= rateTol);
mode = 'steady_rate_band';

if numel(selectedIdx) < cfg.Stage1SteadyMinSamples
    rateTol = 1.5 * rateTol;
    selectedIdx = validIdx(validIdx >= enterIdx & abs(r(validIdx) - rRef) <= rateTol);
    mode = 'steady_rate_band_relaxed';
end

if numel(selectedIdx) < max(5, min(cfg.Stage1SteadyMinSamples, numel(validIdx)))
    selectedIdx = tailIdx;
    mode = 'tail_fallback';
    rRef = median(r(selectedIdx), 'omitnan');
    rateTol = max(abs(r(selectedIdx) - rRef));
    enterIdx = selectedIdx(1);
end

[selectedIdx, residualInfo] = refineStage1ResidualSamples(u, r, selectedIdx, cfg);
if residualInfo.applied
    mode = [mode '_residual'];
end

steadyInfo.mode = mode;
steadyInfo.selectedIdx = columnVector(selectedIdx);
steadyInfo.startTime = timeS(selectedIdx(1));
steadyInfo.rRef = rRef;
steadyInfo.rateTol = rateTol;
steadyInfo.residualTol = residualInfo.threshold;
steadyInfo.residualRemovedCount = residualInfo.removedCount;
steadyInfo.uSel = u(selectedIdx);
steadyInfo.rSel = r(selectedIdx);
steadyInfo.speedSel = speedMps(selectedIdx);
end

function [selectedIdx, residualInfo] = refineStage1ResidualSamples(u, r, selectedIdx, cfg)
selectedIdx = columnVector(selectedIdx);
residualInfo = struct('applied', false, 'threshold', NaN, 'removedCount', 0);
if numel(selectedIdx) < max(5, min(cfg.Stage1SteadyMinSamples, numel(selectedIdx)))
    return;
end

uSel = u(selectedIdx);
rSel = r(selectedIdx);
K0 = fitBranchGain(uSel, rSel);
if ~isfinite(K0)
    return;
end

residual = rSel - K0 * uSel;
residualCenter = median(residual, 'omitnan');
residualMad = median(abs(residual - residualCenter), 'omitnan');
residualScale = 1.4826 * residualMad;
if ~(isfinite(residualScale) && residualScale > eps)
    residualScale = std(residual, 'omitnan');
end

threshold = max(deg2rad(cfg.Stage1ResidualTolDegS), cfg.Stage1ResidualTolSigma * residualScale);
if ~(isfinite(threshold) && threshold > 0)
    return;
end

inlierMask = abs(residual) <= threshold;
if all(inlierMask)
    residualInfo.threshold = threshold;
    return;
end

minKeep = max(5, min(cfg.Stage1SteadyMinSamples, numel(selectedIdx)));
if nnz(inlierMask) < minKeep
    return;
end

selectedIdx = selectedIdx(inlierMask);
residualInfo.applied = true;
residualInfo.threshold = threshold;
residualInfo.removedCount = nnz(~inlierMask);
end

function xFit = buildFitAxis(values)
values = columnVector(values);
values = values(isfinite(values));
if isempty(values)
    xFit = linspace(-1, 1, 100).';
    return;
end

vmin = min(values);
vmax = max(values);
if abs(vmax - vmin) < eps
    pad = max(5, 0.15 * max(abs(vmax), 1));
    xFit = linspace(vmin - pad, vmax + pad, 100).';
else
    pad = 0.08 * (vmax - vmin);
    xFit = linspace(vmin - pad, vmax + pad, 100).';
end
end

function [stageResult, params] = identifyStage2T(data, params, stageFolder, cfg)
style = plotStyle();
u = data.uModelPwm;
r = data.yawRateRadSFiltered;
drdt = data.yawAccelRadS2;
mask = data.analysisMask;

requireSamples(mask, 8, 'stage 2');
requireSignedSamples(u(mask), 5, 'stage 2');

if ~(isfinite(params.KPos) && isfinite(params.KNeg))
    error('阶段2需要阶段1先给出 K+ 和 K-，当前不再执行联合最小二乘回退。');
end

gainSpec = branchGainSpec(params);
weightedInput = branchWeightedInput(u(mask), gainSpec);
basis = drdt(mask);
rhs = weightedInput - r(mask);
den = sum(basis .* basis);
if den <= eps
    error('阶段2中的角速度导数信息过弱，无法稳定辨识 T。');
end

params.T = sum(basis .* rhs) / den;
params.SourceT = 'stage2';

if params.T <= 0
    error('阶段2联合辨识得到的 T <= 0，无法用于后续仿真。');
end

rModel = nomoto_utils.simulateLinearNomoto(data.timeS, u, gainSpec, params.T, r(1));
headingModelDeg = cumtrapz(data.timeS, rad2deg(rModel));

stageResult = struct();
stageResult.method = 'sequential_least_squares_known_K_pos_K_neg';
stageResult.K_pos = params.KPos;
stageResult.K_neg = params.KNeg;
stageResult.K = equivalentBranchK(params.KPos, params.KNeg);
stageResult.asymmetry_ratio = safeBranchRatio(params.KNeg, params.KPos);
stageResult.T = params.T;
stageResult.equation_rmse_rad_s = nomoto_utils.rmse(r(mask), weightedInput - params.T * drdt(mask));
stageResult.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(r, rModel));
stageResult.yaw_rate_r2 = nomoto_utils.rsquared(r, rModel);
stageResult.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingModelDeg);
stageResult.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingModelDeg);

stage2FitX = drdt(mask);
stage2FitY = weightedInput - r(mask);
stage2FitXDeg = rad2deg(stage2FitX);
stage2FitYDeg = rad2deg(stage2FitY);
xMin = min(stage2FitXDeg);
xMax = max(stage2FitXDeg);
if abs(xMax - xMin) <= eps(max(1, max(abs(stage2FitXDeg))))
    xPad = max(1, 0.1 * max(1, abs(xMax)));
    xLine = linspace(xMin - xPad, xMax + xPad, 100).';
else
    xLine = linspace(xMin, xMax, 100).';
end
yLine = params.T * xLine;

figLsq = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', 'stage2_least_squares_fit');
scatter(stage2FitXDeg, stage2FitYDeg, 18, style.pointColor, 'filled');
hold on;
plot(xLine, yLine, '-', 'Color', style.fitColor, 'LineWidth', 1.3);
applyAxesStyle(style);
xlabel('角速度导数 dr/dt (deg/s^2)');
ylabel('K(u-u_{trim}) - r (deg/s)');
title(sprintf('阶段2 最小二乘拟合 T，斜率 = %.6g s', params.T));
legend({'有效样本', '最小二乘拟合'}, 'Location', 'best');
hold off;
stageResult.lsq_figure = saveFigureBundle(figLsq, fullfile(stageFolder, 'stage2_least_squares_fit'), cfg);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段2-T辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
hold on;
plot(data.timeS, rad2deg(rModel), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('阶段2 双支路线性辨识，K+ = %.6g，K- = %.6g，T = %.6g', ...
    params.KPos, params.KNeg, params.T));
legend({'实测值', '线性模型'}, 'Location', 'best');
hold off;

nexttile;
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingModelDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段2 线性模型航向角拟合对比');
legend({'实测值', '线性模型'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage2_identification_T'), cfg);
end

function [stageResult, params] = identifyStage3Alpha(data, params, stageFolder, cfg)
style = plotStyle();
u = data.uModelPwm;
r = data.yawRateRadSFiltered;
drdt = data.yawAccelRadS2;
mask = data.analysisMask;

requireSamples(mask, 8, 'stage 3');
requireSignedSamples(u(mask), 5, 'stage 3');

stageResult = struct();
if ~(isfinite(params.KPos) && isfinite(params.KNeg) && isfinite(params.T))
    error('阶段3需要已知 K+、K-、T，当前不再执行联合最小二乘回退。');
end

basis = r(mask) .^ 3;
rhs = branchWeightedInput(u(mask), params) - r(mask) - params.T * drdt(mask);
den = sum(basis .* basis);
if den <= eps
    error('阶段3中的三次项信息过弱，无法稳定辨识 alpha。');
end
alpha = sum(basis .* rhs) / den;
stageResult.method = 'sequential_least_squares_known_K_pos_K_neg_T';

params.alpha = alpha;
params.SourceAlpha = 'stage3';

gainSpec = branchGainSpec(params);
rNonlinear = nomoto_utils.simulateNonlinearNomoto(data.timeS, u, gainSpec, params.T, alpha, r(1));
headingNonlinearDeg = cumtrapz(data.timeS, rad2deg(rNonlinear));

stageResult.K_pos = params.KPos;
stageResult.K_neg = params.KNeg;
stageResult.K = equivalentBranchK(params.KPos, params.KNeg);
stageResult.T = params.T;
stageResult.alpha = alpha;
stageResult.asymmetry_ratio = safeBranchRatio(params.KNeg, params.KPos);
stageResult.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(r, rNonlinear));
stageResult.yaw_rate_r2 = nomoto_utils.rsquared(r, rNonlinear);
stageResult.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingNonlinearDeg);
stageResult.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingNonlinearDeg);

figFilter = figure('Visible', figureVisibility(cfg), 'Color', 'w');
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
hold on;
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('阶段3 原始离散点与滤波后曲线对比');
legend({'原始离散点', '滤波后曲线'}, 'Location', 'best');
hold off;
stageResult.filter_comparison_figure = saveFigureBundle(figFilter, fullfile(stageFolder, 'stage3_filter_comparison'), cfg);

fig = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段3-alpha辨识');
tiledlayout(fig, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

nexttile;
plotDiscreteSeries(data.timeS, data.yawRateDegS, style.measuredColor);
hold on;
plot(data.timeS, rad2deg(rNonlinear), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title(sprintf('阶段3 双支路 alpha 辨识，K+ = %.6g，K- = %.6g，T = %.6g，alpha = %.6g', ...
    params.KPos, params.KNeg, params.T, alpha));
legend({'实测值', '非线性模型'}, 'Location', 'best');
hold off;

nexttile;
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingNonlinearDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段3 航向角对比');
legend({'实测值', '非线性模型'}, 'Location', 'best');
hold off;

stageResult.figure = saveFigureBundle(fig, fullfile(stageFolder, 'stage3_identification_alpha'), cfg);
end

function stageResult = validateStage4(data, params, stageFolder, cfg)
style = plotStyle();
if ~(isfinite(params.KPos) && isfinite(params.KNeg) && isfinite(params.T) && isfinite(params.alpha))
    error('阶段4双支路非线性模型验证需要已知 K+、K-、T、alpha。');
end

u = data.uModelPwm;
r0 = data.yawRateRadSFiltered(1);
gainSpec = branchGainSpec(params);
rNonlinear = nomoto_utils.simulateNonlinearNomoto(data.timeS, u, gainSpec, params.T, params.alpha, r0);
headingNonlinearDeg = cumtrapz(data.timeS, rad2deg(rNonlinear));
headingErrorDeg = data.headingRelDeg - headingNonlinearDeg;
validHeadingErrorDeg = headingErrorDeg(isfinite(headingErrorDeg));

stageResult = struct();
stageResult.method = 'model_validation';
stageResult.K_pos = params.KPos;
stageResult.K_neg = params.KNeg;
stageResult.K = equivalentBranchK(params.KPos, params.KNeg);
stageResult.T = params.T;
stageResult.alpha = params.alpha;
stageResult.asymmetry_ratio = safeBranchRatio(params.KNeg, params.KPos);
stageResult.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(data.yawRateRadSFiltered, rNonlinear));
stageResult.yaw_rate_r2 = nomoto_utils.rsquared(data.yawRateRadSFiltered, rNonlinear);
stageResult.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingNonlinearDeg);
stageResult.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingNonlinearDeg);
stageResult.heading_error_max_abs_deg = max(abs(headingErrorDeg));
if isempty(validHeadingErrorDeg)
    stageResult.heading_error_min_deg = NaN;
    stageResult.heading_error_max_deg = NaN;
else
    stageResult.heading_error_min_deg = min(validHeadingErrorDeg);
    stageResult.heading_error_max_deg = max(validHeadingErrorDeg);
end

figYawRate = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4角速度验证');
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.measuredColor, 'LineWidth', 1.1);
hold on;
plot(data.timeS, rad2deg(rNonlinear), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
expandYAxis([rad2deg(data.yawRateRadSFiltered); rad2deg(rNonlinear)], 0.18);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('阶段4 角速度验证');
legend({'滤波值', '非线性模型'}, 'Location', 'best');
hold off;

figHeading = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4航向角验证');
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingNonlinearDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
applyAxesStyle(style);
expandYAxis([data.headingRelDeg; headingNonlinearDeg], 0.18);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段4 航向角验证');
legend({'滤波值', '非线性模型'}, 'Location', 'best');
hold off;

stageResult.yaw_rate_figure = saveFigureBundle(figYawRate, fullfile(stageFolder, 'stage4_yaw_rate_validation'), cfg);
stageResult.heading_figure = saveFigureBundle(figHeading, fullfile(stageFolder, 'stage4_heading_validation'), cfg);
stageResult.figure = struct( ...
    'yaw_rate', stageResult.yaw_rate_figure, ...
    'heading', stageResult.heading_figure);

figErr = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4航向角误差');
plot(data.timeS, headingErrorDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
hold on;
yline(0, '--', 'Color', style.referenceColor, 'LineWidth', 1.0);
applyAxesStyle(style);
xlabel('时间 (s)');
ylabel('航向角误差 (deg)');
title(sprintf('阶段4 航向角误差，RMSE = %.3f deg', stageResult.heading_rmse_deg));
legend({'实测-模型误差', '零误差参考线'}, 'Location', 'best');
hold off;

stageResult.heading_error_figure = saveFigureBundle(figErr, fullfile(stageFolder, 'stage4_heading_error'), cfg);
end

function stageResult = validateStage4Compare(data, dualParams, singleParams, stageFolder, cfg)
style = plotStyle();
if ~(isfinite(dualParams.KPos) && isfinite(dualParams.KNeg) && isfinite(dualParams.T) && isfinite(dualParams.alpha))
    error('单/双模型对比验证模式要求双模型参数 K+、K-、T、alpha 可用。');
end
if ~(isfinite(singleParams.K) && isfinite(singleParams.T) && isfinite(singleParams.alpha))
    error('单/双模型对比验证模式要求显式提供单模型 K、T（alpha 可省略，默认 0）。');
end

u = data.uModelPwm;
r0 = data.yawRateRadSFiltered(1);

dualGainSpec = branchGainSpec(dualParams);
rDual = nomoto_utils.simulateNonlinearNomoto(data.timeS, u, dualGainSpec, dualParams.T, dualParams.alpha, r0);
headingDualDeg = cumtrapz(data.timeS, rad2deg(rDual));
headingErrorDualDeg = data.headingRelDeg - headingDualDeg;

rSingle = nomoto_utils.simulateNonlinearNomoto(data.timeS, u, singleParams.K, singleParams.T, singleParams.alpha, r0);
headingSingleDeg = cumtrapz(data.timeS, rad2deg(rSingle));
headingErrorSingleDeg = data.headingRelDeg - headingSingleDeg;

dualValidErr = headingErrorDualDeg(isfinite(headingErrorDualDeg));
singleValidErr = headingErrorSingleDeg(isfinite(headingErrorSingleDeg));

stageResult = struct();
stageResult.method = 'single_dual_compare_validation';
stageResult.K_pos = dualParams.KPos;
stageResult.K_neg = dualParams.KNeg;
stageResult.K = equivalentBranchK(dualParams.KPos, dualParams.KNeg);
stageResult.T = dualParams.T;
stageResult.alpha = dualParams.alpha;
stageResult.asymmetry_ratio = safeBranchRatio(dualParams.KNeg, dualParams.KPos);
stageResult.single_model = buildSingleModelCompareStats(singleParams, data, rSingle, headingSingleDeg, singleValidErr);
stageResult.dual_model = buildDualModelCompareStats(dualParams, data, rDual, headingDualDeg, dualValidErr);

figYawRate = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4角速度验证');
plot(data.timeS, rad2deg(data.yawRateRadSFiltered), '-', 'Color', style.measuredColor, 'LineWidth', 1.1);
hold on;
plot(data.timeS, rad2deg(rDual), '-', 'Color', style.fitColor, 'LineWidth', 1.25);
plot(data.timeS, rad2deg(rSingle), '--', 'Color', style.headingColor, 'LineWidth', 1.25);
applyAxesStyle(style);
expandYAxis([rad2deg(data.yawRateRadSFiltered); rad2deg(rDual); rad2deg(rSingle)], 0.18);
xlabel('时间 (s)');
ylabel('角速度 (deg/s)');
title('阶段4 角速度验证（单/双模型对比）');
legend({'滤波值', '双模型', '单模型(KT)'}, 'Location', 'best');
hold off;

figHeading = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4航向角验证');
plot(data.timeS, data.headingRelDeg, '-', 'Color', style.measuredColor, 'LineWidth', 1.0);
hold on;
plot(data.timeS, headingDualDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
plot(data.timeS, headingSingleDeg, '--', 'Color', style.headingColor, 'LineWidth', 1.25);
applyAxesStyle(style);
expandYAxis([data.headingRelDeg; headingDualDeg; headingSingleDeg], 0.18);
xlabel('时间 (s)');
ylabel('航向角 (deg)');
title('阶段4 航向角验证（单/双模型对比）');
legend({'滤波值', '双模型', '单模型(KT)'}, 'Location', 'best');
hold off;

figErr = figure('Visible', figureVisibility(cfg), 'Color', 'w', 'Name', '阶段4航向角误差');
plot(data.timeS, headingErrorDualDeg, '-', 'Color', style.fitColor, 'LineWidth', 1.25);
hold on;
plot(data.timeS, headingErrorSingleDeg, '--', 'Color', style.headingColor, 'LineWidth', 1.25);
yline(0, '--', 'Color', style.referenceColor, 'LineWidth', 1.0);
applyAxesStyle(style);
expandYAxis([headingErrorDualDeg; headingErrorSingleDeg; 0], 0.18);
xlabel('时间 (s)');
ylabel('航向角误差 (deg)');
title(sprintf('阶段4 航向角误差，双模型 RMSE = %.3f deg，单模型 RMSE = %.3f deg', ...
    stageResult.dual_model.heading_rmse_deg, stageResult.single_model.heading_rmse_deg));
legend({'双模型误差', '单模型误差', '零误差参考线'}, 'Location', 'best');
hold off;

stageResult.yaw_rate_figure = saveFigureBundle(figYawRate, fullfile(stageFolder, 'stage4_yaw_rate_validation'), cfg);
stageResult.heading_figure = saveFigureBundle(figHeading, fullfile(stageFolder, 'stage4_heading_validation'), cfg);
stageResult.heading_error_figure = saveFigureBundle(figErr, fullfile(stageFolder, 'stage4_heading_error'), cfg);
stageResult.figure = struct( ...
    'yaw_rate', stageResult.yaw_rate_figure, ...
    'heading', stageResult.heading_figure, ...
    'heading_error', stageResult.heading_error_figure);
end

function saved = saveSummaryArtifacts(results, cfg)
saved = struct();

matPath = fullfile(cfg.RunOutputRoot, 'nomoto_identification_results.mat');
jsonPath = fullfile(cfg.RunOutputRoot, 'nomoto_identification_results.json');
txtPath = fullfile(cfg.RunOutputRoot, 'nomoto_identification_summary.txt');

save(matPath, 'results');

jsonText = jsonencode(results, PrettyPrint=true);
writeTextFile(jsonPath, jsonText);

summaryLines = {
    sprintf('生成时间：%s', results.generated_at)
    sprintf('搜索目录：%s', results.search_root)
    sprintf('输出目录：%s', results.output_root)
    };

if strcmp(results.run_mode, 'compare_validate')
    summaryLines{end + 1, 1} = sprintf('双模型 K+ 参数：%.12g', results.final_params.K_pos); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('双模型 K- 参数：%.12g', results.final_params.K_neg); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('双模型 K 参数：%.12g', results.final_params.K); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('双模型 T 参数：%.12g', results.final_params.T); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('双模型 alpha 参数：%.12g', results.final_params.alpha); %#ok<AGROW>
    if isfield(results, 'compare_single_params')
        summaryLines{end + 1, 1} = sprintf('单模型 K 参数：%.12g', results.compare_single_params.K); %#ok<AGROW>
        summaryLines{end + 1, 1} = sprintf('单模型 T 参数：%.12g', results.compare_single_params.T); %#ok<AGROW>
        summaryLines{end + 1, 1} = sprintf('单模型 alpha 参数：%.12g', results.compare_single_params.alpha); %#ok<AGROW>
    end
    if isfield(results.stage_results, 'stage4')
        stage4 = results.stage_results.stage4;
        summaryLines{end + 1, 1} = sprintf('双模型航向角 RMSE：%.6f deg', stage4.dual_model.heading_rmse_deg); %#ok<AGROW>
        summaryLines{end + 1, 1} = sprintf('单模型航向角 RMSE：%.6f deg', stage4.single_model.heading_rmse_deg); %#ok<AGROW>
        summaryLines{end + 1, 1} = sprintf('双模型辨识误差：[%.6f, %.6f] deg', ... %#ok<AGROW>
            stage4.dual_model.heading_error_min_deg, stage4.dual_model.heading_error_max_deg);
        summaryLines{end + 1, 1} = sprintf('单模型辨识误差：[%.6f, %.6f] deg', ... %#ok<AGROW>
            stage4.single_model.heading_error_min_deg, stage4.single_model.heading_error_max_deg);
    end
else
    summaryLines{end + 1, 1} = sprintf('K+ 参数：%.12g', results.final_params.K_pos); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('K- 参数：%.12g', results.final_params.K_neg); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('K 参数：%.12g', results.final_params.K); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('T 参数：%.12g', results.final_params.T); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('alpha 参数：%.12g', results.final_params.alpha); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('u_trim 参数：%.12g', results.final_params.u_trim); %#ok<AGROW>
end

summaryLines{end + 1, 1} = ''; %#ok<AGROW>
summaryLines{end + 1, 1} = '本次选中的文件：'; %#ok<AGROW>

if isfield(results.stage_results, 'stage1') && isfield(results.stage_results.stage1, 'turning_radius_m') ...
        && isfinite(results.stage_results.stage1.turning_radius_m)
    summaryLines{end + 1, 1} = sprintf('stage1 回转半径：%.6f m', results.stage_results.stage1.turning_radius_m); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('stage1 回转直径：%.6f m', results.stage_results.stage1.turning_diameter_m); %#ok<AGROW>
    summaryLines{end + 1, 1} = sprintf('stage1 尾段平均航速：%.6f m/s', results.stage_results.stage1.mean_speed_mps); %#ok<AGROW>
    summaryLines{end + 1, 1} = ''; %#ok<AGROW>
end

for i = 1:numel(results.selected_files)
    summaryLines{end + 1, 1} = sprintf('  阶段 %d -> %s', ...
        results.selected_files(i).stage_id, results.selected_files(i).file_path); %#ok<AGROW>
end

writeTextFile(txtPath, strjoin(summaryLines, newline));

saved.mat = matPath;
saved.json = jsonPath;
saved.txt = txtPath;
end

function params = initializeParams(cfg, cached)
params = struct();
params.KPos = NaN;
params.KNeg = NaN;
params.T = NaN;
params.alpha = NaN;
params.SourceKPos = '';
params.SourceKNeg = '';
params.SourceT = '';
params.SourceAlpha = '';

if ~isempty(cached)
    if isfield(cached, 'final_params')
        finalParams = cached.final_params;
        if isfield(finalParams, 'K_pos')
            params.KPos = finalParams.K_pos;
            params.SourceKPos = 'cache';
        end
        if isfield(finalParams, 'K_neg')
            params.KNeg = finalParams.K_neg;
            params.SourceKNeg = 'cache';
        end
        if isfield(finalParams, 'K') && isfinite(finalParams.K)
            if ~isfinite(params.KPos)
                params.KPos = finalParams.K;
                params.SourceKPos = 'cache_legacy';
            end
            if ~isfinite(params.KNeg)
                params.KNeg = finalParams.K;
                params.SourceKNeg = 'cache_legacy';
            end
        end
        if isfield(finalParams, 'T')
            params.T = finalParams.T;
            params.SourceT = 'cache';
        end
        if isfield(finalParams, 'alpha')
            params.alpha = finalParams.alpha;
            params.SourceAlpha = 'cache';
        end
    end
end

if isfinite(cfg.OverrideK)
    params.KPos = cfg.OverrideK;
    params.KNeg = cfg.OverrideK;
    params.SourceKPos = 'override_shared';
    params.SourceKNeg = 'override_shared';
end
if isfinite(cfg.OverrideKPos)
    params.KPos = cfg.OverrideKPos;
    params.SourceKPos = 'override';
end
if isfinite(cfg.OverrideKNeg)
    params.KNeg = cfg.OverrideKNeg;
    params.SourceKNeg = 'override';
end
if isfinite(cfg.OverrideT)
    params.T = cfg.OverrideT;
    params.SourceT = 'override';
end
if isfinite(cfg.OverrideAlpha)
    params.alpha = cfg.OverrideAlpha;
    params.SourceAlpha = 'override';
end
params.UTrim = cfg.UTrim;
params.SourceUTrim = 'config';
end

function params = initializeValidationParams(cfg)
params = struct();
params.KPos = cfg.OverrideKPos;
params.KNeg = cfg.OverrideKNeg;
params.T = cfg.OverrideT;
params.alpha = cfg.OverrideAlpha;
params.UTrim = cfg.UTrim;
params.SourceKPos = 'validate_input';
params.SourceKNeg = 'validate_input';
params.SourceT = 'validate_input';
params.SourceAlpha = 'validate_input';
params.SourceUTrim = 'config';

if isfinite(cfg.OverrideK)
    params.KPos = cfg.OverrideK;
    params.KNeg = cfg.OverrideK;
    params.SourceKPos = 'validate_input_shared';
    params.SourceKNeg = 'validate_input_shared';
end

if ~(isfinite(params.KPos) && isfinite(params.KNeg) && isfinite(params.T) && isfinite(params.alpha))
    error('验证模式要求显式提供 K+、K-、T、alpha。');
end
end

function params = initializeCompareSingleParams(cfg)
params = struct();
params.K = cfg.CompareSingleK;
params.T = cfg.CompareSingleT;
params.alpha = cfg.CompareSingleAlpha;
params.SourceK = 'compare_input';
params.SourceT = 'compare_input';
params.SourceAlpha = 'compare_input';

if ~(isfinite(params.K) && isfinite(params.T))
    error('单/双模型对比验证模式要求显式提供单模型 K 和 T。');
end
if ~isfinite(params.alpha)
    params.alpha = 0.0;
    params.SourceAlpha = 'compare_default_zero';
end
end

function cached = loadLatestCache(cacheFile, fallbackCacheFile)
cached = struct([]);
if nargin < 2
    fallbackCacheFile = '';
end

candidateFiles = {cacheFile};
if strlength(string(fallbackCacheFile)) > 0
    fallbackCacheFile = char(string(fallbackCacheFile));
    if ~strcmpi(fallbackCacheFile, char(string(cacheFile)))
        candidateFiles{end + 1} = fallbackCacheFile; %#ok<AGROW>
    end
end

for i = 1:numel(candidateFiles)
    currentFile = char(string(candidateFiles{i}));
    if ~isfile(currentFile)
        continue;
    end
    try
        data = load(currentFile, 'results');
        if isfield(data, 'results')
            cached = data.results;
            return;
        end
    catch
        cached = struct([]);
    end
end
end

function out = paramsToStruct(params)
out = struct();
out.K_pos = params.KPos;
out.K_neg = params.KNeg;
out.K = equivalentBranchK(params.KPos, params.KNeg);
out.T = params.T;
out.alpha = params.alpha;
out.u_trim = params.UTrim;
out.K_source = combinedSourceText(params.SourceKPos, params.SourceKNeg);
out.K_pos_source = params.SourceKPos;
out.K_neg_source = params.SourceKNeg;
out.T_source = params.SourceT;
out.alpha_source = params.SourceAlpha;
out.u_trim_source = params.SourceUTrim;
out.model_variant = 'dual_branch_gain';
end

function out = compareParamsToStruct(params)
out = struct();
out.K = params.K;
out.T = params.T;
out.alpha = params.alpha;
out.K_source = params.SourceK;
out.T_source = params.SourceT;
out.alpha_source = params.SourceAlpha;
out.model_variant = 'single_gain_compare';
end

function out = buildSingleModelCompareStats(params, data, rModel, headingModelDeg, validHeadingErrorDeg)
headingErrorDeg = data.headingRelDeg - headingModelDeg;
out = struct();
out.K = params.K;
out.T = params.T;
out.alpha = params.alpha;
out.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(data.yawRateRadSFiltered, rModel));
out.yaw_rate_r2 = nomoto_utils.rsquared(data.yawRateRadSFiltered, rModel);
out.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingModelDeg);
out.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingModelDeg);
out.heading_error_max_abs_deg = max(abs(headingErrorDeg));
if isempty(validHeadingErrorDeg)
    out.heading_error_min_deg = NaN;
    out.heading_error_max_deg = NaN;
else
    out.heading_error_min_deg = min(validHeadingErrorDeg);
    out.heading_error_max_deg = max(validHeadingErrorDeg);
end
end

function out = buildDualModelCompareStats(params, data, rModel, headingModelDeg, validHeadingErrorDeg)
headingErrorDeg = data.headingRelDeg - headingModelDeg;
out = struct();
out.K_pos = params.KPos;
out.K_neg = params.KNeg;
out.K = equivalentBranchK(params.KPos, params.KNeg);
out.T = params.T;
out.alpha = params.alpha;
out.asymmetry_ratio = safeBranchRatio(params.KNeg, params.KPos);
out.yaw_rate_rmse_deg_s = rad2deg(nomoto_utils.rmse(data.yawRateRadSFiltered, rModel));
out.yaw_rate_r2 = nomoto_utils.rsquared(data.yawRateRadSFiltered, rModel);
out.heading_rmse_deg = nomoto_utils.rmse(data.headingRelDeg, headingModelDeg);
out.heading_r2 = nomoto_utils.rsquared(data.headingRelDeg, headingModelDeg);
out.heading_error_max_abs_deg = max(abs(headingErrorDeg));
if isempty(validHeadingErrorDeg)
    out.heading_error_min_deg = NaN;
    out.heading_error_max_deg = NaN;
else
    out.heading_error_min_deg = min(validHeadingErrorDeg);
    out.heading_error_max_deg = max(validHeadingErrorDeg);
end
end

function value = fitBranchGain(uBranch, rBranch)
if isempty(uBranch)
    value = NaN;
    return;
end

den = sum(uBranch .* uBranch);
if den <= eps
    value = NaN;
    return;
end
value = sum(uBranch .* rBranch) / den;
end

function gainSpec = branchGainSpec(params)
gainSpec = struct('K_pos', params.KPos, 'K_neg', params.KNeg);
end

function weighted = branchWeightedInput(u, gainSpec)
weighted = nomoto_utils.applySignedGain(u, gainSpec);
end

function value = equivalentBranchK(KPos, KNeg)
finiteValues = [KPos, KNeg];
finiteValues = finiteValues(isfinite(finiteValues));
if isempty(finiteValues)
    value = NaN;
else
    value = mean(finiteValues);
end
end

function value = safeBranchRatio(numerator, denominator)
if ~(isfinite(numerator) && isfinite(denominator) && abs(denominator) > eps)
    value = NaN;
else
    value = numerator / denominator;
end
end

function value = maskedMean(values)
if isempty(values)
    value = NaN;
else
    value = mean(values);
end
end

function textValue = combinedSourceText(sourcePos, sourceNeg)
sourcePos = char(string(sourcePos));
sourceNeg = char(string(sourceNeg));
if isempty(sourcePos) && isempty(sourceNeg)
    textValue = '';
elseif strcmp(sourcePos, sourceNeg)
    textValue = sourcePos;
else
    textValue = sprintf('K_pos:%s; K_neg:%s', sourcePos, sourceNeg);
end
end

function uPos = positiveInput(u)
uPos = max(columnVector(u), 0);
end

function uNeg = negativeInput(u)
uNeg = min(columnVector(u), 0);
end

function headingRelDeg = buildRelativeHeading(headingDeg, relativeHeadingDeg, accumTurnDeg, yawRateDegS, timeS)
if ~isempty(relativeHeadingDeg) && any(isfinite(relativeHeadingDeg))
    headingRelDeg = columnVector(relativeHeadingDeg);
    headingRelDeg = headingRelDeg - headingRelDeg(1);
    return;
end

if ~isempty(accumTurnDeg) && any(isfinite(accumTurnDeg))
    headingRelDeg = columnVector(accumTurnDeg);
    headingRelDeg = headingRelDeg - headingRelDeg(1);
    return;
end

if ~isempty(headingDeg) && any(isfinite(headingDeg))
    headingRad = unwrap(deg2rad(columnVector(headingDeg)));
    headingRelDeg = rad2deg(headingRad - headingRad(1));
    return;
end

headingRelDeg = cumtrapz(timeS, yawRateDegS);
headingRelDeg = columnVector(headingRelDeg);
end

function headingAbsDeg = buildAbsoluteHeading(headingDeg)
if isempty(headingDeg) || ~any(isfinite(headingDeg))
    headingAbsDeg = [];
    return;
end
headingAbsDeg = columnVector(headingDeg);
end

function requireSamples(mask, minCount, stageName)
if nnz(mask) < minCount
    error('%s 可用有效样本不足，无法完成辨识。', stageName);
end
end

function requireSignedSamples(u, minCount, stageName)
u = columnVector(u);
posCount = nnz(u > 0);
negCount = nnz(u < 0);
if posCount < minCount || negCount < minCount
    error('%s 正负两个支路的有效样本不足，无法稳定辨识 K+ / K-。', stageName);
end
end

function style = plotStyle()
style = struct();
style.measuredColor = [0.34, 0.16, 0.52];
style.inputColor = [0.30, 0.30, 0.30];
style.fitColor = [0.74, 0.21, 0.14];
style.referenceColor = [0.58, 0.65, 0.72];
style.headingColor = [0.00, 0.43, 0.32];
style.speedColor = [0.58, 0.42, 0.20];
style.pointColor = [0.34, 0.16, 0.52];
end

function applyAxesStyle(~)
grid on;
box on;
ax = gca;
ax.LineWidth = 0.9;
ax.FontSize = 10;
ax.GridAlpha = 0.18;
ax.MinorGridAlpha = 0.08;
ax.XColor = [0.15, 0.15, 0.15];
ax.YColor = [0.15, 0.15, 0.15];
end

function expandYAxis(values, paddingRatio)
values = values(isfinite(values));
if isempty(values)
    return;
end

yMin = min(values);
yMax = max(values);
ySpan = yMax - yMin;
if ySpan <= eps
    yPad = max(1.0, 0.15 * max(abs([yMin, yMax])));
else
    yPad = paddingRatio * ySpan;
end
ylim([yMin - yPad, yMax + yPad]);
end

function h = plotDiscreteSeries(x, y, colorSpec)
h = scatter(x, y, 18, colorSpec, 'filled', ...
    'MarkerEdgeColor', [1, 1, 1], 'LineWidth', 0.45);
end

function saved = saveFigureBundle(fig, basePath, cfg)
saved = struct('eps', '', 'fig', '');
drawnow;

if cfg.SaveEpsFigures
    epsPath = [basePath '.eps'];
    exportgraphics(fig, epsPath, 'ContentType', 'vector');
    saved.eps = epsPath;
end

if isfield(cfg, 'SaveMatFigures') && cfg.SaveMatFigures
    figPath = [basePath '.fig'];
    savefig(fig, figPath);
    saved.fig = figPath;
end

if ~cfg.ShowFigures
    close(fig);
end
end

function modeText = figureVisibility(cfg)
if cfg.ShowFigures
    modeText = 'on';
else
    modeText = 'off';
end
end

function value = getOption(opts, fieldName, defaultValue)
if isfield(opts, fieldName) && ~isempty(opts.(fieldName))
    value = opts.(fieldName);
else
    value = defaultValue;
end
end

function value = getNumericOption(opts, fieldName, defaultValue)
value = getOption(opts, fieldName, defaultValue);
if isempty(value)
    value = defaultValue;
end
value = double(value);
if ~isscalar(value)
    error('选项 %s 必须为标量。', fieldName);
end
end

function value = getNumericOptionAliases(opts, fieldNames, defaultValue)
for i = 1:numel(fieldNames)
    fieldName = fieldNames{i};
    if isfield(opts, fieldName) && ~isempty(opts.(fieldName))
        value = double(opts.(fieldName));
        if ~isscalar(value)
            error('选项 %s 必须为标量。', fieldName);
        end
        return;
    end
end
value = defaultValue;
end

function value = meanFinite(values)
values = columnVector(values);
values = values(isfinite(values));
if isempty(values)
    value = NaN;
else
    value = mean(values);
end
end

function radiusM = estimateTurningRadius(speedMps, yawRateRadS)
if ~(isfinite(speedMps) && isfinite(yawRateRadS) && abs(yawRateRadS) > eps)
    radiusM = NaN;
else
    radiusM = abs(speedMps / yawRateRadS);
end
end

function modeText = parseRunMode(rawMode)
modeText = lower(strtrim(char(string(rawMode))));
switch modeText
    case {'identify', 'identification', 'fit', '辨识', '杈ㄨ瘑'}
        modeText = 'identify';
    case {'validate', 'validation', 'verify', '验证', '楠岃瘉'}
        modeText = 'validate';
    case {'compare_validate', 'compare', 'comparevalidation', 'single_dual_compare', '对比验证'}
        modeText = 'compare_validate';
    otherwise
        error('Mode only supports identify / validate / compare_validate.');
end
end

function ensureFolder(folderPath)
if ~isfolder(folderPath)
    mkdir(folderPath);
end
end

function names = normalizeNames(variableNames)
names = strings(size(variableNames));
for i = 1:numel(variableNames)
    name = lower(char(string(variableNames{i})));
    name = regexprep(name, '[^a-z0-9]+', '_');
    name = regexprep(name, '^_+|_+$', '');
    names(i) = string(name);
end
names = cellstr(names);
end

function values = numericColumn(tbl, normalizedNames, candidateNames, required)
if nargin < 4
    required = true;
end

idx = findColumnIndex(normalizedNames, candidateNames);
if isempty(idx)
    if required
        error('缺少必要列：%s', strjoin(candidateNames, ', '));
    else
        values = [];
        return;
    end
end

values = tbl{:, idx};
if iscell(values)
    values = str2double(values);
elseif isstring(values)
    values = str2double(values);
elseif ischar(values)
    values = str2double(cellstr(values));
elseif istable(values)
    values = table2array(values);
end
values = columnVector(values);
end

function values = textColumn(tbl, normalizedNames, candidateNames, required)
if nargin < 4
    required = true;
end

idx = findColumnIndex(normalizedNames, candidateNames);
if isempty(idx)
    if required
        error('缺少必要的文本列：%s', strjoin(candidateNames, ', '));
    else
        values = strings(0, 1);
        return;
    end
end

values = tbl{:, idx};
if iscell(values)
    values = string(values);
elseif ischar(values)
    values = string(cellstr(values));
elseif ~isstring(values)
    values = string(values);
end
values = columnVector(values);
end

function idx = findColumnIndex(normalizedNames, candidateNames)
idx = [];
for i = 1:numel(candidateNames)
    candidate = lower(candidateNames{i});
    candidate = regexprep(candidate, '[^a-z0-9]+', '_');
    candidate = regexprep(candidate, '^_+|_+$', '');
    match = find(strcmp(normalizedNames, candidate), 1, 'first');
    if ~isempty(match)
        idx = match;
        return;
    end
end
end

function x = columnVector(x)
if isempty(x)
    return;
end
x = x(:);
end

function arr = reorderAndColumn(arr, order)
if isempty(arr)
    arr = [];
    return;
end
arr = columnVector(arr);
arr = arr(order);
end

function arr = cropOptional(arr, mask)
if isempty(arr)
    return;
end
arr = columnVector(arr);
arr = arr(mask);
end

function arr = cropOptionalByIndex(arr, idx)
if isempty(arr)
    return;
end
arr = columnVector(arr);
arr = arr(idx);
end

function arr = optionalColumn(arr, count)
if isempty(arr)
    arr = nan(count, 1);
else
    arr = columnVector(arr);
end
end

function timestampText = extractTimestampText(filePath)
[~, name] = fileparts(filePath);
token = regexp(name, '(\d{8}_\d{6})$', 'tokens', 'once');
if isempty(token)
    timestampText = '';
else
    timestampText = token{1};
end
end

function writeTextFile(filePath, textBody)
fid = fopen(filePath, 'w', 'n', 'UTF-8');
if fid < 0
    error('无法写入文件：%s', filePath);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s', textBody);
end
