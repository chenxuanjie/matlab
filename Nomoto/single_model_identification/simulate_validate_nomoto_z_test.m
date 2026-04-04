%% Nomoto Z 型实验仿真与验证脚本
% 模型形式：
%   线性 K-T 模型：T * dr/dt + r = K * delta(t)
%   非线性模型：   T * dr/dt + r + alpha * r^3 = K * delta(t)
%
% 状态含义：
%   r   : 艏摇角速度
%   psi : 航向角，满足 dpsi/dt = r
%
% 本脚本适合在你已经识别出 K、T（以及 alpha）之后，
% 用“PWM 差值”来执行 Z 型实验仿真，并可进一步与 CSV 实验数据做对比验证。
%
% 功能包括：
% 1. 根据给定 PWM 差值自动生成 Z 型实验输入
% 2. 计算航向角随时间变化曲线
% 3. 可选读取 CSV 实验数据，与仿真结果同图对比
% 4. 可选绘制航向角误差曲线，并输出 RMSE / MAE / 最大绝对误差
%
% 重要说明：
% 1. 你当前给的是 PWM 差值，而不是直接的舵角 delta。
% 2. 由于目前没有“PWM 差值 -> 实际舵角”的标定关系，
%    本脚本默认采用“线性等效映射”：
%
%       abs(pwmDiff) = 1000  <->  abs(delta) = 15 deg
%
%    你可以在“PWM 差值与等效舵角映射区”自行修改。
% 3. 你给出的控制约定是：
%    - PWM 为正：船左转，航向角增加
%    - PWM 为负：船右转，航向角减小
%    脚本会自动结合 K 的符号，把 PWM 差值映射到模型输入 delta。

clc;
clear;
close all;

%% ======================== 模型参数区 ========================

% 模型类型：
% 'linearKT'  -> 只使用线性 K-T 模型，忽略 alpha
% 'nonlinear' -> 使用完整非线性 Nomoto 模型
modelType = 'nonlinear';

% 已识别的 Nomoto 参数
K = -0.9600004;
T = 0.052562502;
alpha = -1.6382E-05;

%% ======================== 仿真参数区（可直接修改） ========================

% 仿真总时长（秒）
totalTime = 30;

% 主时间步长（秒）
% 你要求使用 0.1 s，这里默认已设置为 0.1
dt = 0.1;

% 每个主时间步内部再细分多少个积分子步
% 当 T 比较小、dt 相对较大时，适当增加该值可提高仿真稳定性和精度
integrationSubsteps = 10;

% 初始航向角（度）
% 设为 65 可更接近你给的示意图风格；如果想从 0 开始，改成 0 即可
psi0Deg = 65;

% 初始艏摇角速度（deg/s）
r0DegPerSec = 0;

%% ======================== Z 型实验控制参数区（可直接修改） ========================

% Z 型实验切换阈值（度）
% 例如 15 表示做 Z15°/15° 实验
zSwitchYawDeg = 15;

% 输入 PWM 差值幅值
% 该值在 Z 型实验中会按 +A、-A、+A、-A ... 的方式切换
% 合法范围建议在 [-1000, 1000] 内
zPwmDiffAmplitude = 300;

% 初始控制方向：
% +1 -> 先打正 PWM（按你的定义：航向角增加）
% -1 -> 先打负 PWM（航向角减小）
initialCommandSign = +1;

% PWM 差值允许的最大绝对值
pwmDiffLimit = 1000;

%% ======================== PWM 差值与等效舵角映射区（可直接修改） ========================

% PWM 差值满量程
% 当 abs(pwmDiff) = pwmDiffFullScale 时，认为对应“满量程等效舵角”
pwmDiffFullScale = 1000;

% 满量程 PWM 差值对应的等效舵角（度）
% 当前默认假设：abs(pwmDiff) = 1000 <-> abs(delta) = 15 deg
equivalentDeltaAtFullScaleDeg = 15;

% PWM 正值是否表示“航向角增加”
% 你当前说明为 true
pwmPositiveMeansHeadingIncrease = true;

%% ======================== CSV 验证配置区（可直接修改） ========================

% 是否启用 CSV 验证
enableValidation = true;

% 验证 CSV 文件路径
% 可以填绝对路径，也可以填相对于本脚本所在目录的相对路径
validationCsvFile = 'example_csv/nomoto_z_validation_example.csv';

% CSV 分隔符
csvDelimiter = ',';

% CSV 中时间列、航向角列、PWM 差值列
% 既可以写列名，也可以写列序号
csvTimeColumn = 'time_s';
csvYawColumn = 'yaw_deg';
csvPwmDiffColumn = 'pwm_diff';

% 是否把 CSV 时间起点平移到 0 秒
normalizeValidationTimeToZero = true;

% 是否使用 CSV 中的 PWM 差值作为仿真输入
% true  -> 直接按实验 PWM 差值驱动 Nomoto 模型，更适合做“验证”
% false -> 使用上面“Z 型实验控制参数区”中的理想 Z 型输入
useCsvPwmDiffForSimulation = true;

% 是否使用 CSV 的总时长覆盖仿真总时长
useCsvDurationAsTotalTime = true;

% 如果实验航向角存在 360/0 跳变，可设为 true 做解包角处理
unwrapMeasuredYaw = false;

%% ======================== 绘图与误差显示区（可直接修改） ========================

showControlFigure = true;
showYawErrorFigure = true;

% 是否绘制误差阈值线
showYawErrorThreshold = true;

% 误差阈值（度）
yawErrorThresholdDeg = 5;

% 曲线标签
measuredLegendText = 'Z 型实验数据';
simulatedLegendText = 'Nomoto 仿真数据';

%% ======================== 参数检查 ========================

if T <= 0
    error('T 必须大于 0。');
end

if dt <= 0
    error('dt 必须大于 0。');
end

if integrationSubsteps < 1 || round(integrationSubsteps) ~= integrationSubsteps
    error('integrationSubsteps 必须为正整数。');
end

if abs(zPwmDiffAmplitude) > pwmDiffLimit
    error('zPwmDiffAmplitude 超出允许范围，请保证其绝对值不超过 pwmDiffLimit。');
end

if pwmDiffFullScale <= 0
    error('pwmDiffFullScale 必须大于 0。');
end

if equivalentDeltaAtFullScaleDeg <= 0
    error('equivalentDeltaAtFullScaleDeg 必须大于 0。');
end

if zSwitchYawDeg <= 0
    error('zSwitchYawDeg 必须大于 0。');
end

if K == 0
    warning('当前 K = 0，模型不会对控制输入产生响应。');
end

%% ======================== 读取验证 CSV（可选） ========================

csvData = struct();
if enableValidation
    scriptDir = fileparts(mfilename('fullpath'));
    resolvedCsvFile = resolveInputPath(validationCsvFile, scriptDir);
    csvData = readValidationCsv(resolvedCsvFile, csvDelimiter, csvTimeColumn, csvYawColumn, csvPwmDiffColumn, ...
        normalizeValidationTimeToZero, unwrapMeasuredYaw);

    fprintf('验证 CSV 读取完成。\n');
    fprintf('CSV 文件：%s\n', resolvedCsvFile);
    fprintf('样本点数：%d\n', numel(csvData.time));
    fprintf('时间范围：%.3f s ~ %.3f s\n', csvData.time(1), csvData.time(end));
end

%% ======================== 建立仿真时间轴 ========================

if enableValidation && useCsvDurationAsTotalTime
    totalTime = csvData.time(end);
end

time = (0:dt:totalTime).';
sampleCount = numel(time);

fprintf('仿真设置：\n');
fprintf('模型类型：%s\n', modelType);
fprintf('总时长：%.3f s\n', totalTime);
fprintf('时间步长：%.3f s\n', dt);
fprintf('样本点数：%d\n', sampleCount);
fprintf('Z 型阈值：±%.1f deg\n', zSwitchYawDeg);
fprintf('PWM 差值幅值：%d\n', round(zPwmDiffAmplitude));

%% ======================== 确定仿真输入 ========================

if enableValidation && useCsvPwmDiffForSimulation
    pwmDiffCommand = interp1(csvData.time, csvData.pwmDiff, time, 'previous', 'extrap');
    controlSourceText = 'csv_pwm';
else
    pwmDiffCommand = [];
    controlSourceText = 'generated_z';
end

%% ======================== 执行仿真 ========================

cfg = struct();
cfg.modelType = modelType;
cfg.K = K;
cfg.T = T;
cfg.alpha = alpha;
cfg.dt = dt;
cfg.integrationSubsteps = integrationSubsteps;
cfg.psi0Rad = deg2rad(psi0Deg);
cfg.r0RadPerSec = deg2rad(r0DegPerSec);
cfg.zSwitchYawDeg = zSwitchYawDeg;
cfg.zPwmDiffAmplitude = zPwmDiffAmplitude;
cfg.initialCommandSign = signOrDefault(initialCommandSign, 1);
cfg.pwmDiffFullScale = pwmDiffFullScale;
cfg.equivalentDeltaAtFullScaleDeg = equivalentDeltaAtFullScaleDeg;
cfg.pwmPositiveMeansHeadingIncrease = pwmPositiveMeansHeadingIncrease;
cfg.pwmDiffLimit = pwmDiffLimit;

if strcmpi(controlSourceText, 'generated_z')
    simResult = simulateGeneratedZTest(time, cfg);
else
    simResult = simulateNomotoWithGivenPwm(time, pwmDiffCommand, cfg);
end

fprintf('仿真完成。\n');
fprintf('控制来源：%s\n', controlSourceText);
fprintf('最终航向角：%.3f deg\n', simResult.psiDeg(end));
fprintf('最终艏摇角速度：%.3f deg/s\n', simResult.rDegPerSec(end));
fprintf('Z 型切换次数：%d\n', simResult.switchCount);

%% ======================== 误差计算（可选） ========================

measuredYawOnSimTime = [];
yawErrorDeg = [];
rmseYawDeg = NaN;
maeYawDeg = NaN;
maxAbsYawErrorDeg = NaN;

if enableValidation
    measuredYawOnSimTime = interp1(csvData.time, csvData.yawDeg, time, 'linear', 'extrap');
    yawErrorDeg = measuredYawOnSimTime - simResult.psiDeg;

    rmseYawDeg = sqrt(mean(yawErrorDeg .^ 2));
    maeYawDeg = mean(abs(yawErrorDeg));
    maxAbsYawErrorDeg = max(abs(yawErrorDeg));

    fprintf('验证结果：\n');
    fprintf('航向角 RMSE = %.4f deg\n', rmseYawDeg);
    fprintf('航向角 MAE  = %.4f deg\n', maeYawDeg);
    fprintf('航向角最大绝对误差 = %.4f deg\n', maxAbsYawErrorDeg);
end

%% ======================== 图 1：PWM 差值输入 ========================

if showControlFigure
    figure('Name', 'Nomoto Z Test - PWM Input', 'Color', 'w');
    hold on;
    stairs(time, simResult.pwmDiff, '-', 'Color', [0.20, 0.35, 0.85], 'LineWidth', 1.4, ...
        'DisplayName', 'PWM 差值输入');
    applyThesisAxesStyle();
    xlabel('时间 (s)');
    ylabel('PWM 差值');
    legend('Location', 'best');
    hold off;
end

%% ======================== 图 2：航向角对比/仿真图 ========================

figure('Name', 'Nomoto Z Test - Yaw', 'Color', 'w');
hold on;

if enableValidation
    plot(time, measuredYawOnSimTime, '-', 'Color', [0.92, 0.12, 0.12], 'LineWidth', 1.8, ...
        'DisplayName', measuredLegendText);
    plot(time, simResult.psiDeg, '--', 'Color', [0.10, 0.30, 0.92], 'LineWidth', 1.8, ...
        'DisplayName', simulatedLegendText);
else
    plot(time, simResult.psiDeg, '-', 'Color', [0.10, 0.30, 0.92], 'LineWidth', 1.8, ...
        'DisplayName', 'Nomoto 仿真航向角');
end

applyThesisAxesStyle();
xlabel('时间 (s)');
ylabel('航向角 / °');
legend('Location', 'best');
hold off;

%% ======================== 图 3：航向角误差图（可选） ========================

if enableValidation && showYawErrorFigure
    figure('Name', 'Nomoto Z Test - Yaw Error', 'Color', 'w');
    hold on;
    plot(time, yawErrorDeg, '-', 'Color', [0.10, 0.30, 0.92], 'LineWidth', 1.4, ...
        'DisplayName', '航向角误差');

    if showYawErrorThreshold
        yline(yawErrorThresholdDeg, '--', 'Color', [0.92, 0.20, 0.20], 'LineWidth', 1.1, ...
            'DisplayName', sprintf('阈值 = %.1f°', yawErrorThresholdDeg));
        yline(-yawErrorThresholdDeg, '--', 'Color', [0.92, 0.20, 0.20], 'LineWidth', 1.1, ...
            'HandleVisibility', 'off');
    end

    yline(0, '--', 'Color', [0.35, 0.35, 0.35], 'LineWidth', 1.0, 'HandleVisibility', 'off');
    applyThesisAxesStyle();
    xlabel('时间 (s)');
    ylabel('误差 / °');
    legend('Location', 'best');
    hold off;
end

%% ======================== 输出结果结构体 ========================

result = struct();
result.time = time;
result.pwmDiff = simResult.pwmDiff;
result.deltaEquivalentDeg = simResult.deltaEquivalentDeg;
result.rDegPerSec = simResult.rDegPerSec;
result.psiDeg = simResult.psiDeg;
result.switchCount = simResult.switchCount;
result.switchTime = simResult.switchTime;
result.switchHeadingDeg = simResult.switchHeadingDeg;
result.controlSource = controlSourceText;
result.modelType = modelType;
result.K = K;
result.T = T;
result.alpha = alpha;

if enableValidation
    result.measuredYawDeg = measuredYawOnSimTime;
    result.yawErrorDeg = yawErrorDeg;
    result.rmseYawDeg = rmseYawDeg;
    result.maeYawDeg = maeYawDeg;
    result.maxAbsYawErrorDeg = maxAbsYawErrorDeg;
    result.validationCsv = resolvedCsvFile;
end

fprintf('脚本运行完成。\n');

%% ======================== 本地函数区 ========================

function simResult = simulateGeneratedZTest(time, cfg)
% 生成理想 Z 型实验输入，并同步完成 Nomoto 模型仿真。

    sampleCount = numel(time);
    pwmDiff = zeros(sampleCount, 1);
    deltaEquivalentDeg = zeros(sampleCount, 1);
    rRad = zeros(sampleCount, 1);
    psiRad = zeros(sampleCount, 1);

    switchTime = [];
    switchHeadingDeg = [];

    pwmDiff(1) = cfg.initialCommandSign * abs(cfg.zPwmDiffAmplitude);
    rRad(1) = cfg.r0RadPerSec;
    psiRad(1) = cfg.psi0Rad;

    for k = 1:(sampleCount - 1)
        currentPwmDiff = saturatePwmDiff(pwmDiff(k), cfg.pwmDiffLimit);
        [currentDeltaRad, currentDeltaDeg] = pwmDiffToModelDelta(currentPwmDiff, cfg);
        deltaEquivalentDeg(k) = currentDeltaDeg;

        [nextR, nextPsi] = integrateOneMainStep(rRad(k), psiRad(k), currentDeltaRad, cfg);
        rRad(k + 1) = nextR;
        psiRad(k + 1) = nextPsi;

        relativePsiDeg = rad2deg(psiRad(k + 1) - cfg.psi0Rad);
        nextPwmDiff = currentPwmDiff;

        if currentPwmDiff > 0 && relativePsiDeg >= cfg.zSwitchYawDeg
            nextPwmDiff = -abs(cfg.zPwmDiffAmplitude);
            switchTime(end + 1, 1) = time(k + 1); %#ok<AGROW>
            switchHeadingDeg(end + 1, 1) = rad2deg(psiRad(k + 1)); %#ok<AGROW>
        elseif currentPwmDiff < 0 && relativePsiDeg <= -cfg.zSwitchYawDeg
            nextPwmDiff = abs(cfg.zPwmDiffAmplitude);
            switchTime(end + 1, 1) = time(k + 1); %#ok<AGROW>
            switchHeadingDeg(end + 1, 1) = rad2deg(psiRad(k + 1)); %#ok<AGROW>
        end

        pwmDiff(k + 1) = nextPwmDiff;
    end

    [~, deltaEquivalentDeg(end)] = pwmDiffToModelDelta(pwmDiff(end), cfg);

    simResult = packSimulationResult(pwmDiff, deltaEquivalentDeg, rRad, psiRad, switchTime, switchHeadingDeg);
end

function simResult = simulateNomotoWithGivenPwm(time, pwmDiffCommand, cfg)
% 使用给定 PWM 差值序列驱动 Nomoto 模型。

    sampleCount = numel(time);
    pwmDiff = ensureColumn(pwmDiffCommand);

    if numel(pwmDiff) ~= sampleCount
        error('给定 PWM 差值序列长度与时间向量长度不一致。');
    end

    deltaEquivalentDeg = zeros(sampleCount, 1);
    rRad = zeros(sampleCount, 1);
    psiRad = zeros(sampleCount, 1);

    rRad(1) = cfg.r0RadPerSec;
    psiRad(1) = cfg.psi0Rad;

    switchTime = [];
    switchHeadingDeg = [];

    for k = 1:(sampleCount - 1)
        currentPwmDiff = saturatePwmDiff(pwmDiff(k), cfg.pwmDiffLimit);
        pwmDiff(k) = currentPwmDiff;

        [currentDeltaRad, currentDeltaDeg] = pwmDiffToModelDelta(currentPwmDiff, cfg);
        deltaEquivalentDeg(k) = currentDeltaDeg;

        [nextR, nextPsi] = integrateOneMainStep(rRad(k), psiRad(k), currentDeltaRad, cfg);
        rRad(k + 1) = nextR;
        psiRad(k + 1) = nextPsi;

        if signWithZero(currentPwmDiff) ~= signWithZero(pwmDiff(k + 1))
            switchTime(end + 1, 1) = time(k + 1); %#ok<AGROW>
            switchHeadingDeg(end + 1, 1) = rad2deg(psiRad(k + 1)); %#ok<AGROW>
        end
    end

    pwmDiff(end) = saturatePwmDiff(pwmDiff(end), cfg.pwmDiffLimit);
    [~, deltaEquivalentDeg(end)] = pwmDiffToModelDelta(pwmDiff(end), cfg);

    simResult = packSimulationResult(pwmDiff, deltaEquivalentDeg, rRad, psiRad, switchTime, switchHeadingDeg);
end

function [nextR, nextPsi] = integrateOneMainStep(currentR, currentPsi, currentDeltaRad, cfg)
% 在一个主时间步内，使用多个积分子步推进状态。

    subDt = cfg.dt / cfg.integrationSubsteps;
    nextR = currentR;
    nextPsi = currentPsi;

    for subIndex = 1:cfg.integrationSubsteps
        oldR = nextR;

        switch lower(cfg.modelType)
            case 'linearkt'
                decayFactor = exp(-subDt / cfg.T);
                nextR = decayFactor * nextR + cfg.K * currentDeltaRad * (1 - decayFactor);
            case 'nonlinear'
                k1 = nonlinearRhs(nextR, currentDeltaRad, cfg.K, cfg.T, cfg.alpha);
                k2 = nonlinearRhs(nextR + 0.5 * subDt * k1, currentDeltaRad, cfg.K, cfg.T, cfg.alpha);
                k3 = nonlinearRhs(nextR + 0.5 * subDt * k2, currentDeltaRad, cfg.K, cfg.T, cfg.alpha);
                k4 = nonlinearRhs(nextR + subDt * k3, currentDeltaRad, cfg.K, cfg.T, cfg.alpha);
                nextR = nextR + (subDt / 6) * (k1 + 2 * k2 + 2 * k3 + k4);
            otherwise
                error('未知模型类型：%s', cfg.modelType);
        end

        nextPsi = nextPsi + 0.5 * (oldR + nextR) * subDt;
    end
end

function value = nonlinearRhs(r, delta, K, T, alpha)
% 非线性 Nomoto 模型右端函数。

    value = (K * delta - r - alpha * r.^3) / T;
end

function [deltaRad, deltaDeg] = pwmDiffToModelDelta(pwmDiff, cfg)
% 将 PWM 差值映射为模型中的等效舵角 delta。

    normalizedMagnitude = abs(pwmDiff) / cfg.pwmDiffFullScale;
    equivalentDeltaMagnitudeDeg = normalizedMagnitude * cfg.equivalentDeltaAtFullScaleDeg;

    kSign = signOrDefault(cfg.K, 1);
    if cfg.pwmPositiveMeansHeadingIncrease
        modelDeltaSignForPositivePwm = kSign;
    else
        modelDeltaSignForPositivePwm = -kSign;
    end

    deltaDeg = modelDeltaSignForPositivePwm * signWithZero(pwmDiff) * equivalentDeltaMagnitudeDeg;
    deltaRad = deg2rad(deltaDeg);
end

function simResult = packSimulationResult(pwmDiff, deltaEquivalentDeg, rRad, psiRad, switchTime, switchHeadingDeg)
% 打包仿真输出结构体。

    simResult = struct();
    simResult.pwmDiff = ensureColumn(pwmDiff);
    simResult.deltaEquivalentDeg = ensureColumn(deltaEquivalentDeg);
    simResult.rRadPerSec = ensureColumn(rRad);
    simResult.rDegPerSec = rad2deg(ensureColumn(rRad));
    simResult.psiRad = ensureColumn(psiRad);
    simResult.psiDeg = rad2deg(ensureColumn(psiRad));
    simResult.switchTime = switchTime;
    simResult.switchHeadingDeg = switchHeadingDeg;
    simResult.switchCount = numel(switchTime);
end

function csvData = readValidationCsv(csvFile, delimiter, timeColumn, yawColumn, pwmDiffColumn, normalizeTimeToZero, unwrapYaw)
% 读取验证 CSV 数据。

    if ~isfile(csvFile)
        error('找不到验证 CSV 文件：%s', csvFile);
    end

    try
        if strlength(string(delimiter)) == 0
            tbl = readtable(csvFile);
        else
            tbl = readtable(csvFile, 'Delimiter', char(string(delimiter)));
        end
    catch readErr
        error('读取验证 CSV 失败：%s\n原因：%s', csvFile, readErr.message);
    end

    time = extractFlexibleColumn(tbl, timeColumn, {'time', 'time_s', 't'});
    yawDeg = extractFlexibleColumn(tbl, yawColumn, {'yaw_deg', 'psi_deg', 'heading_deg'});
    pwmDiff = extractFlexibleColumn(tbl, pwmDiffColumn, {'pwm_diff', 'delta_pwm', 'pwm'});

    time = ensureColumn(time);
    yawDeg = ensureColumn(yawDeg);
    pwmDiff = ensureColumn(pwmDiff);

    validMask = isfinite(time) & isfinite(yawDeg) & isfinite(pwmDiff);
    time = time(validMask);
    yawDeg = yawDeg(validMask);
    pwmDiff = pwmDiff(validMask);

    if isempty(time)
        error('验证 CSV 中没有有效数据。');
    end

    [time, sortIdx] = sort(time);
    yawDeg = yawDeg(sortIdx);
    pwmDiff = pwmDiff(sortIdx);

    if normalizeTimeToZero
        time = time - time(1);
    end

    if unwrapYaw
        yawDeg = rad2deg(unwrap(deg2rad(yawDeg)));
    end

    [time, uniqueIdx] = unique(time, 'stable');
    yawDeg = yawDeg(uniqueIdx);
    pwmDiff = pwmDiff(uniqueIdx);

    csvData = struct();
    csvData.time = time;
    csvData.yawDeg = yawDeg;
    csvData.pwmDiff = pwmDiff;
end

function values = extractFlexibleColumn(tbl, columnSpec, fallbackNames)
% 从表格中提取目标列。

    if isnumeric(columnSpec)
        columnIndex = round(columnSpec);
        if columnIndex < 1 || columnIndex > size(tbl, 2)
            error('列序号 %d 超出了表格范围。', columnIndex);
        end
        values = tbl{:, columnIndex};
        values = convertColumnToNumeric(values);
        return;
    end

    requestedName = char(string(columnSpec));
    candidateNames = unique([{requestedName}, fallbackNames], 'stable');
    variableNames = tbl.Properties.VariableNames;

    for i = 1:numel(candidateNames)
        matchedIndex = matchColumnName(variableNames, candidateNames{i});
        if ~isempty(matchedIndex)
            values = tbl{:, matchedIndex};
            values = convertColumnToNumeric(values);
            return;
        end
    end

    error('找不到列 "%s"。', requestedName);
end

function matchedIndex = matchColumnName(variableNames, requestedName)
% 按完全匹配、忽略大小写、合法变量名三种方式匹配列名。

    matchedIndex = find(strcmp(variableNames, requestedName), 1, 'first');
    if ~isempty(matchedIndex)
        return;
    end

    matchedIndex = find(strcmpi(variableNames, requestedName), 1, 'first');
    if ~isempty(matchedIndex)
        return;
    end

    safeRequestedName = matlab.lang.makeValidName(requestedName);
    matchedIndex = find(strcmp(variableNames, safeRequestedName), 1, 'first');
    if ~isempty(matchedIndex)
        return;
    end

    matchedIndex = find(strcmpi(variableNames, safeRequestedName), 1, 'first');
end

function values = convertColumnToNumeric(values)
% 尽量将表格列转换为数值类型。

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
end

function resolvedPath = resolveInputPath(inputPath, scriptDir)
% 解析输入路径。

    if isfile(inputPath)
        resolvedPath = inputPath;
        return;
    end

    candidatePath = fullfile(scriptDir, inputPath);
    if isfile(candidatePath)
        resolvedPath = candidatePath;
    else
        resolvedPath = inputPath;
    end
end

function values = ensureColumn(values)
% 转成列向量。

    values = values(:);
end

function value = saturatePwmDiff(value, limitValue)
% 对 PWM 差值进行限幅。

    value = max(-limitValue, min(limitValue, value));
end

function signValue = signOrDefault(value, defaultValue)
% 当 value 为 0 时，返回默认符号。

    signValue = sign(value);
    if signValue == 0
        signValue = defaultValue;
    end
end

function signValue = signWithZero(value)
% 带零值保留的符号函数。

    if value > 0
        signValue = 1;
    elseif value < 0
        signValue = -1;
    else
        signValue = 0;
    end
end

function applyThesisAxesStyle()
% 统一设置更适合论文插图的坐标轴风格。

    grid on;
    box on;
    ax = gca;
    ax.LineWidth = 0.9;
    ax.FontSize = 11;
end
