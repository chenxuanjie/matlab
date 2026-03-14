%% 非线性 Nomoto 模型参数识别：K
% 模型形式：T * dr/dt + r + alpha * r^3 = K * delta
%
% 本脚本只识别 K。
% 基本思想：
% 1. 从文件中读取 time、delta、r 数据。
% 2. 按舵角变化自动分段。
% 3. 对每个阶段取尾部一部分样本，作为稳态点。
% 4. 用稳态关系 r_ss ≈ K * delta_ss 识别 K。
%
% 适用建议：
% - 尽量使用小舵角、分段恒定舵角试验数据。
% - 尽量保证每个舵角阶段都有足够长的稳态段。
% - 如果自动分段效果不好，优先调整“分段参数区”的阈值和窗口长度。

clc;
clear;
close all;

%% ======================== 文件与列配置区 ========================

cfg = struct();

% 数据文件路径
cfg.dataFile = 'your_k_data.csv';

% 读取模式：
% 'auto'     -> 先尝试 readtable，再尝试 key=value 解析
% 'table'    -> 强制按表格文件读取（csv/txt/xlsx 等）
% 'keyvalue' -> 强制按每行 key=value 形式读取
cfg.readMode = 'auto';

% 三个数据列：既可以写列名，也可以写列序号
cfg.timeColumn = 'time';
cfg.deltaColumn = 'delta';
cfg.rColumn = 'r';

% 若 readtable 自动识别分隔符失败，可手动指定，如 ',' 或 '\t'
cfg.tableDelimiter = ',';

%% ======================== 单位与预处理配置区 ========================

% 角度单位：'deg' 或 'rad'
cfg.angleUnit = 'deg';

% 角速度单位：'deg/s' 或 'rad/s'
cfg.yawRateUnit = 'deg/s';

% 是否只截取某一段时间的数据参与识别
cfg.enableTimeWindow = false;
cfg.timeWindow = [0, 100];

% 是否进行移动平均滤波
cfg.enableFilter = true;
cfg.filterWindow = 5;

% 时间坐标单位标签，仅用于绘图显示
cfg.timeUnitLabel = 's';

%% ======================== 分段参数区 ========================

% 自动分段时，若相邻样本平滑后舵角变化超过该阈值，则认为进入新阶段
% 该阈值使用“原始角度单位”填写，例如 deg。
deltaChangeThreshold = 0.3;

% 分段前对舵角做平滑的窗口长度（样本点数）
segmentSmoothWindow = 5;

% 单个阶段至少保留多少个样本点
minSegmentSamples = 20;

%% ======================== 稳态提取与拟合参数区 ========================

% 每个阶段最后多少比例的数据用于计算稳态平均值
steadyTailFraction = 0.30;

% 每段至少用多少个点参与稳态平均
minSteadySamples = 10;

% 拟合时忽略绝对值过小的舵角阶段，避免 0 舵角影响识别
minAbsDeltaForFit = 1.0;

% 是否强制拟合过原点：r = K * delta
% 对 Nomoto 一阶模型，通常建议设为 true
fitThroughOrigin = true;

%% ======================== 读取数据 ========================

data = nomoto_utils.readData(cfg);

fprintf('K 识别数据读取完成。\n');
fprintf('样本点数：%d\n', data.sampleCount);
fprintf('读取模式：%s\n', data.sourceMode);

%% ======================== 自动分段并提取稳态点 ========================

deltaChangeThresholdRad = nomoto_utils.angleToRad(deltaChangeThreshold, cfg.angleUnit);
minAbsDeltaForFitRad = nomoto_utils.angleToRad(minAbsDeltaForFit, cfg.angleUnit);

segments = nomoto_utils.splitByStepSegments( ...
    data, deltaChangeThresholdRad, segmentSmoothWindow, minSegmentSamples);

steady = nomoto_utils.extractSteadyPoints(segments, steadyTailFraction, minSteadySamples);

fitMask = abs(steady.delta) >= minAbsDeltaForFitRad;
if ~any(fitMask)
    error('没有满足拟合条件的稳态段，请减小 minAbsDeltaForFit 或检查数据。');
end

steadyDeltaFit = steady.delta(fitMask);
steadyRFit = steady.r(fitMask);

%% ======================== 识别 K ========================

if fitThroughOrigin
    K = nomoto_utils.estimateKThroughOrigin(steadyDeltaFit, steadyRFit);
    intercept = 0;
    predictedR = K * steadyDeltaFit;
else
    coeff = polyfit(steadyDeltaFit, steadyRFit, 1);
    K = coeff(1);
    intercept = coeff(2);
    predictedR = polyval(coeff, steadyDeltaFit);
end

rmseValue = nomoto_utils.rmse(steadyRFit, predictedR);
r2Value = nomoto_utils.rsquared(steadyRFit, predictedR);

fprintf('\n===== K 识别结果 =====\n');
fprintf('K = %.8f 1/s\n', K);
if ~fitThroughOrigin
    fprintf('intercept = %.8f rad/s\n', intercept);
end
fprintf('稳态点数量 = %d\n', numel(steadyDeltaFit));
fprintf('RMSE = %.8f rad/s\n', rmseValue);
fprintf('R^2 = %.6f\n', r2Value);

%% ======================== 图 1：原始时序数据 ========================

deltaPlot = nomoto_utils.angleFromRad(data.delta, cfg.angleUnit);
rPlot = nomoto_utils.rateFromRad(data.r, cfg.yawRateUnit);
steadyDeltaPlot = nomoto_utils.angleFromRad(steady.delta, cfg.angleUnit);
steadyRPlot = nomoto_utils.rateFromRad(steady.r, cfg.yawRateUnit);

style = nomoto_utils.thesisPlotStyle();

figure('Name', 'K Identification - Time Series', 'Color', 'w');
subplot(2, 1, 1);
plot(data.time, deltaPlot, '-', 'Color', style.inputColor, 'LineWidth', style.lineWidth);
nomoto_utils.applyThesisAxesStyle(style);
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['\delta (' nomoto_utils.angleUnitLabel(cfg.angleUnit) ')']);
title('舵角时序数据');

subplot(2, 1, 2);
yLimits = [min(rPlot), max(rPlot)];
if abs(yLimits(2) - yLimits(1)) < eps
    yLimits = yLimits + [-1, 1] * 1e-6;
end
hold on;
for i = 1:numel(segments)
    x1 = segments(i).time(1);
    x2 = segments(i).time(end);
    patch([x1 x2 x2 x1], [yLimits(1) yLimits(1) yLimits(2) yLimits(2)], style.segmentPatchColor, ...
        'FaceAlpha', 0.18, 'EdgeColor', 'none', 'HandleVisibility', 'off');
end
hMeasured = plot(data.time, rPlot, '-', 'Color', style.measuredColor, ...
    'LineWidth', style.lineWidth, 'DisplayName', '实测 r');
hSteady = scatter(steady.timeEnd, steadyRPlot, style.pointSize, 'o', ...
    'MarkerFaceColor', style.pointColor, ...
    'MarkerEdgeColor', style.pointColor, ...
    'LineWidth', 0.6, ...
    'DisplayName', '稳态点');
nomoto_utils.applyThesisAxesStyle(style);
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['r (' nomoto_utils.rateUnitLabel(cfg.yawRateUnit) ')']);
title('艏摇角速度时序数据与稳态点位置');
legend([hMeasured, hSteady], 'Location', 'best');
hold off;

%% ======================== 图 2：稳态点拟合图 ========================

figure('Name', 'K Identification - Steady Fit', 'Color', 'w');
hold on;
scatter(steadyDeltaPlot(fitMask), steadyRPlot(fitMask), style.pointSize + 10, 'o', ...
    'MarkerFaceColor', style.pointColor, ...
    'MarkerEdgeColor', style.pointColor, ...
    'LineWidth', 0.6, ...
    'DisplayName', '稳态散点');

xFit = linspace(min(steadyDeltaFit), max(steadyDeltaFit), 300).';
if fitThroughOrigin
    yFit = K * xFit;
else
    yFit = K * xFit + intercept;
end

plot(nomoto_utils.angleFromRad(xFit, cfg.angleUnit), ...
    nomoto_utils.rateFromRad(yFit, cfg.yawRateUnit), ...
    '-', 'Color', style.fitColor, 'LineWidth', style.fitLineWidth, 'DisplayName', '最小二乘拟合');

nomoto_utils.applyThesisAxesStyle(style);
xlabel(['稳态舵角 \delta_{ss} (' nomoto_utils.angleUnitLabel(cfg.angleUnit) ')']);
ylabel(['稳态艏摇角速度 r_{ss} (' nomoto_utils.rateUnitLabel(cfg.yawRateUnit) ')']);

if fitThroughOrigin
    title({ ...
        'K 参数识别：稳态点拟合'; ...
        sprintf('r_{ss} = K \cdot \delta_{ss},   K = %.8f 1/s', K); ...
        sprintf('RMSE = %.8f rad/s,   R^2 = %.6f', rmseValue, r2Value) ...
        });
else
    title({ ...
        'K 参数识别：稳态点拟合'; ...
        sprintf('r_{ss} = %.8f \cdot \delta_{ss} + %.8f', K, intercept); ...
        sprintf('RMSE = %.8f rad/s,   R^2 = %.6f', rmseValue, r2Value) ...
        });
end

legend('Location', 'best');
hold off;
%% ======================== 命令行输出每段稳态值 ========================

fprintf('\n===== 各稳态段统计 =====\n');
for i = 1:numel(segments)
    fprintf('阶段 %2d: delta_ss = %8.4f %s, r_ss = %8.4f %s, 稳态点数 = %d\n', ...
        i, ...
        nomoto_utils.angleFromRad(steady.delta(i), cfg.angleUnit), nomoto_utils.angleUnitLabel(cfg.angleUnit), ...
        nomoto_utils.rateFromRad(steady.r(i), cfg.yawRateUnit), nomoto_utils.rateUnitLabel(cfg.yawRateUnit), ...
        steady.pointCount(i));
end



