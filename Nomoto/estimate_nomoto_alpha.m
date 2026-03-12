%% 非线性 Nomoto 模型参数识别：alpha
% 模型形式：T * dr/dt + r + alpha * r^3 = K * delta
%
% 本脚本在已知 K 和 T 的前提下识别 alpha。
%
% 基本思想：
% 1. 读取 time、delta、r 数据。
% 2. 给定 K 和 T。
% 3. 对不同候选 alpha 进行非线性模型时域仿真。
% 4. 通过最小化“模型 r 与实测 r 的误差”来得到最优 alpha。
%
% 适用建议：
% - alpha 更适合使用大舵角、非线性明显的数据来识别。
% - 若你想验证非线性项是否必要，可对比 alpha=0 的线性模型和识别后的非线性模型。

clc;
clear;
close all;

%% ======================== 文件与列配置区 ========================

cfg = struct();

% 数据文件路径
cfg.dataFile = 'your_alpha_data.csv';

% 读取模式：'auto' / 'table' / 'keyvalue'
cfg.readMode = 'auto';

% 三个数据列：可以写列名或列号
cfg.timeColumn = 'time';
cfg.deltaColumn = 'delta';
cfg.rColumn = 'r';

% 必要时手动指定分隔符
cfg.tableDelimiter = ',';

%% ======================== 单位与预处理配置区 ========================

cfg.angleUnit = 'deg';
cfg.yawRateUnit = 'deg/s';

% 是否只用某个时间范围来拟合 alpha
cfg.enableTimeWindow = false;
cfg.timeWindow = [0, 120];

% 是否滤波
cfg.enableFilter = true;
cfg.filterWindow = 5;

% 时间轴标签，仅用于显示
cfg.timeUnitLabel = 's';

%% ======================== 已知参数与搜索范围 ========================

% 这里填写你已经识别出来的 K 和 T
knownK = 0.12000000;
knownT = 8.00000000;

% alpha 的搜索区间
% 注意：alpha 的数量级和你的数据单位、船模工况有关，必要时请手动扩大或缩小
alphaSearchRange = [-5000, 5000];

% 初始艏摇角速度设置：
% 'measured' -> 用第一点实测值
% 'zero'     -> 初值为 0
initialConditionMode = 'measured';

%% ======================== 读取数据 ========================

data = nomoto_utils.readData(cfg);

fprintf('alpha 识别数据读取完成。\n');
fprintf('样本点数：%d\n', data.sampleCount);
fprintf('读取模式：%s\n', data.sourceMode);

if knownT <= 0
    error('knownT 必须大于 0。');
end

if alphaSearchRange(2) <= alphaSearchRange(1)
    error('alphaSearchRange 设置无效，请保证上界 > 下界。');
end

switch lower(initialConditionMode)
    case 'measured'
        r0 = data.r(1);
    case 'zero'
        r0 = 0;
    otherwise
        error('initialConditionMode 仅支持 measured 或 zero。');
end

%% ======================== 通过最小化时域误差识别 alpha ========================

objectiveFunction = @(alpha) nomoto_utils.rmse( ...
    data.r, nomoto_utils.simulateNonlinearNomoto(data.time, data.delta, knownK, knownT, alpha, r0));

options = optimset('TolX', 1e-6, 'Display', 'iter');
[estimatedAlpha, bestRmse] = fminbnd(objectiveFunction, alphaSearchRange(1), alphaSearchRange(2), options);

rLinearModel = nomoto_utils.simulateLinearNomoto(data.time, data.delta, knownK, knownT, r0);
rNonlinearModel = nomoto_utils.simulateNonlinearNomoto(data.time, data.delta, knownK, knownT, estimatedAlpha, r0);

rmseLinear = nomoto_utils.rmse(data.r, rLinearModel);
rmseNonlinear = nomoto_utils.rmse(data.r, rNonlinearModel);
r2Linear = nomoto_utils.rsquared(data.r, rLinearModel);
r2Nonlinear = nomoto_utils.rsquared(data.r, rNonlinearModel);

fprintf('\n===== alpha 识别结果 =====\n');
fprintf('已知 K = %.8f 1/s\n', knownK);
fprintf('已知 T = %.8f %s\n', knownT, cfg.timeUnitLabel);
fprintf('估计得到 alpha = %.8f\n', estimatedAlpha);
fprintf('优化目标 RMSE = %.8f rad/s\n', bestRmse);
fprintf('线性模型 RMSE = %.8f rad/s, R^2 = %.6f\n', rmseLinear, r2Linear);
fprintf('非线性模型 RMSE = %.8f rad/s, R^2 = %.6f\n', rmseNonlinear, r2Nonlinear);

%% ======================== 图 1：舵角输入时序 ========================

deltaPlot = nomoto_utils.angleFromRad(data.delta, cfg.angleUnit);
figure('Name', 'Alpha Identification - Delta Input', 'Color', 'w');
plot(data.time, deltaPlot, 'b-', 'LineWidth', 1.2);
grid on;
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['\delta (' nomoto_utils.angleUnitLabel(cfg.angleUnit) ')']);
title('用于 alpha 识别的舵角输入');

%% ======================== 图 2：实测 / 线性 / 非线性 三者对比 ========================

rMeasuredPlot = nomoto_utils.rateFromRad(data.r, cfg.yawRateUnit);
rLinearPlot = nomoto_utils.rateFromRad(rLinearModel, cfg.yawRateUnit);
rNonlinearPlot = nomoto_utils.rateFromRad(rNonlinearModel, cfg.yawRateUnit);

figure('Name', 'Alpha Identification - Model Comparison', 'Color', 'w');
subplot(2, 1, 1);
plot(data.time, rMeasuredPlot, 'k-', 'LineWidth', 1.2, 'DisplayName', 'Measured r');
hold on;
plot(data.time, rLinearPlot, 'b--', 'LineWidth', 1.3, 'DisplayName', 'Linear model');
plot(data.time, rNonlinearPlot, 'r-', 'LineWidth', 1.5, 'DisplayName', 'Nonlinear model');
grid on;
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['r (' nomoto_utils.rateUnitLabel(cfg.yawRateUnit) ')']);
title({ ...
    'alpha 参数识别：线性模型与非线性模型对比'; ...
    sprintf('K = %.8f 1/s,   T = %.8f %s,   alpha = %.8f', knownK, knownT, cfg.timeUnitLabel, estimatedAlpha); ...
    sprintf('Linear RMSE = %.8f, Nonlinear RMSE = %.8f (rad/s)', rmseLinear, rmseNonlinear) ...
    });
legend('Location', 'best');
hold off;

subplot(2, 1, 2);
residualLinearPlot = nomoto_utils.rateFromRad(data.r - rLinearModel, cfg.yawRateUnit);
residualNonlinearPlot = nomoto_utils.rateFromRad(data.r - rNonlinearModel, cfg.yawRateUnit);
plot(data.time, residualLinearPlot, 'b--', 'LineWidth', 1.2, 'DisplayName', 'Measured - Linear');
hold on;
plot(data.time, residualNonlinearPlot, 'r-', 'LineWidth', 1.2, 'DisplayName', 'Measured - Nonlinear');
grid on;
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['Error (' nomoto_utils.rateUnitLabel(cfg.yawRateUnit) ')']);
title('线性与非线性模型残差对比');
legend('Location', 'best');
hold off;

%% ======================== 命令行补充说明 ========================

fprintf('\n说明：\n');
fprintf('1. alpha 是在已知 K、T 的前提下，通过非线性时域拟合得到的。\n');
fprintf('2. 如果非线性模型相比线性模型并没有明显改善 RMSE / R^2，\n');
fprintf('   说明当前数据中的非线性特征可能不明显。\n');
fprintf('3. 若识别不稳定，可优先：\n');
fprintf('   - 选用更大舵角的数据；\n');
fprintf('   - 缩小时间窗口，只保留有效操纵段；\n');
fprintf('   - 调整 alphaSearchRange 的上下界。\n');
