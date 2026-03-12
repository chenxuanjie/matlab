%% 非线性 Nomoto 模型参数识别：T
% 模型形式：T * dr/dt + r + alpha * r^3 = K * delta
%
% 本脚本在已知 K 的前提下识别 T。
% 识别时采用线性一阶 Nomoto 模型：
%     T * dr/dt + r = K * delta
%
% 基本思想：
% 1. 读取 time、delta、r 数据。
% 2. 给定 K。
% 3. 对不同候选 T 进行时域仿真。
% 4. 通过最小化“模型 r 与实测 r 的误差”来得到最优 T。
%
% 适用建议：
% - 优先使用阶跃舵角、小舵角动态响应数据。
% - 如果文件里包含很多无关时间段，建议开启时间窗口，只截取一段典型操纵过程。

clc;
clear;
close all;

%% ======================== 文件与列配置区 ========================

cfg = struct();

% 数据文件路径
cfg.dataFile = 'your_t_data.csv';

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

% 是否只用某个时间范围来拟合 T
cfg.enableTimeWindow = false;
cfg.timeWindow = [0, 80];

% 是否滤波
cfg.enableFilter = true;
cfg.filterWindow = 5;

% 时间轴标签，仅用于显示
cfg.timeUnitLabel = 's';

%% ======================== 已知参数与搜索范围 ========================

% 这里填写你已经识别出来的 K
knownK = 0.12000000;

% T 的搜索区间（单位与 time 一致）
TSearchRange = [0.1, 100.0];

% 初始艏摇角速度设置：
% 'measured' -> 用当前数据第一点的实测 r 作为初值
% 'zero'     -> 初值设为 0
initialConditionMode = 'measured';

%% ======================== 读取数据 ========================

data = nomoto_utils.readData(cfg);

fprintf('T 识别数据读取完成。\n');
fprintf('样本点数：%d\n', data.sampleCount);
fprintf('读取模式：%s\n', data.sourceMode);

if TSearchRange(1) <= 0 || TSearchRange(2) <= TSearchRange(1)
    error('TSearchRange 设置无效，请保证下界 > 0 且上界 > 下界。');
end

switch lower(initialConditionMode)
    case 'measured'
        r0 = data.r(1);
    case 'zero'
        r0 = 0;
    otherwise
        error('initialConditionMode 仅支持 measured 或 zero。');
end

%% ======================== 通过最小化时域误差识别 T ========================

objectiveFunction = @(T) nomoto_utils.rmse( ...
    data.r, nomoto_utils.simulateLinearNomoto(data.time, data.delta, knownK, T, r0));

options = optimset('TolX', 1e-6, 'Display', 'iter');
[estimatedT, bestRmse] = fminbnd(objectiveFunction, TSearchRange(1), TSearchRange(2), options);

rModel = nomoto_utils.simulateLinearNomoto(data.time, data.delta, knownK, estimatedT, r0);
r2Value = nomoto_utils.rsquared(data.r, rModel);

fprintf('\n===== T 识别结果 =====\n');
fprintf('已知 K = %.8f 1/s\n', knownK);
fprintf('估计得到 T = %.8f %s\n', estimatedT, cfg.timeUnitLabel);
fprintf('RMSE = %.8f rad/s\n', bestRmse);
fprintf('R^2 = %.6f\n', r2Value);

%% ======================== 图 1：舵角输入时序 ========================

deltaPlot = nomoto_utils.angleFromRad(data.delta, cfg.angleUnit);
figure('Name', 'T Identification - Delta Input', 'Color', 'w');
plot(data.time, deltaPlot, 'b-', 'LineWidth', 1.2);
grid on;
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['\delta (' nomoto_utils.angleUnitLabel(cfg.angleUnit) ')']);
title('用于 T 识别的舵角输入');

%% ======================== 图 2：实测 r 与线性模型 r 对比 ========================

rMeasuredPlot = nomoto_utils.rateFromRad(data.r, cfg.yawRateUnit);
rModelPlot = nomoto_utils.rateFromRad(rModel, cfg.yawRateUnit);

figure('Name', 'T Identification - Model Comparison', 'Color', 'w');
subplot(2, 1, 1);
plot(data.time, rMeasuredPlot, 'k-', 'LineWidth', 1.2, 'DisplayName', 'Measured r');
hold on;
plot(data.time, rModelPlot, 'r--', 'LineWidth', 1.5, 'DisplayName', 'Nomoto model');
grid on;
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['r (' nomoto_utils.rateUnitLabel(cfg.yawRateUnit) ')']);
title({ ...
    'T 参数识别：实测与模型对比'; ...
    sprintf('K = %.8f 1/s,   T = %.8f %s', knownK, estimatedT, cfg.timeUnitLabel); ...
    sprintf('RMSE = %.8f rad/s,   R^2 = %.6f', bestRmse, r2Value) ...
    });
legend('Location', 'best');
hold off;

subplot(2, 1, 2);
residualPlot = nomoto_utils.rateFromRad(data.r - rModel, cfg.yawRateUnit);
plot(data.time, residualPlot, 'b-', 'LineWidth', 1.1);
grid on;
xlabel(['Time (' cfg.timeUnitLabel ')']);
ylabel(['Error (' nomoto_utils.rateUnitLabel(cfg.yawRateUnit) ')']);
title('残差：Measured r - Model r');

%% ======================== 命令行补充说明 ========================

fprintf('\n说明：\n');
fprintf('1. T 是通过时域仿真误差最小化得到的。\n');
fprintf('2. 若拟合效果不好，建议：\n');
fprintf('   - 只截取单次阶跃舵角响应区间；\n');
fprintf('   - 调整滤波窗口；\n');
fprintf('   - 重新检查 K 的取值是否合理。\n');
