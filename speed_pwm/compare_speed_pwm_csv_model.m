function result = compare_speed_pwm_csv_model(csvFile, varargin)
%COMPARE_SPEED_PWM_CSV_MODEL 使用 CSV 中的 PWM-速度数据与二次模型做对比。
%
%   RESULT = COMPARE_SPEED_PWM_CSV_MODEL(CSVFILE) 从 CSV 文件中读取 PWM 和
%   速度数据，绘制实测 PWM-speed 特性点，并与已识别的二次模型
%
%       u = k1 * n^2 + k2 * n + k3
%
%   进行对比，同时绘制实测曲线与模型之间的误差图。
%
%   RESULT = COMPARE_SPEED_PWM_CSV_MODEL() 不带输入参数时，会弹出文件选择框，
%   由用户手动选择一个 CSV 文件。
%
%   RESULT = COMPARE_SPEED_PWM_CSV_MODEL(..., 'PwmColumn', 'pwm',
%   'SpeedColumn', 'speed', 'K1', ..., 'K2', ..., 'K3', ...) 可用于：
%   1. 指定 CSV 中 PWM 列和速度列的列名或列序号
%   2. 覆盖默认的模型系数
%   3. 指定分隔符
%
%   本脚本的绘图风格与 plot_pwm_speed_analysis.m 中的稳态 PWM-speed 图尽量保持一致：
%   - 实测数据：紫色散点
%   - 识别模型：红色曲线

    %% ======================== 输入配置区（可直接修改） ========================
    % 说明：
    % 1. 如果你直接点击“运行”本文件，且没有在命令行传入参数，
    %    则默认使用下面这组配置。
    % 2. 如果你在命令行手动传入 csvFile 或 Name-Value 参数，
    %    则手动传入的参数优先级更高。
    % 3. 对大多数情况，你只需要改下面这几个变量：
    %    - defaultCsvFile
    %    - defaultPwmColumn
    %    - defaultSpeedColumn
    %    - defaultK1 / defaultK2 / defaultK3

    % 默认 CSV 文件路径
    % 可以填绝对路径，也可以填相对于本脚本所在文件夹的相对路径
    defaultCsvFile = 'experiment_tests/pwm_ramp_experiment.csv';

    % 当 defaultCsvFile 为空时，是否弹出文件选择框
    % true  -> 弹窗选择 CSV 文件
    % false -> 直接报错，提醒你去修改 defaultCsvFile
    useFileDialogWhenCsvFileEmpty = true;

    % CSV 中 PWM 列的默认列名
    % 可填列名，例如 'pwm'
    % 也可在命令行里传列序号，例如 1
    defaultPwmColumn = 'pwm';

    % CSV 中速度列的默认列名
    % 可填列名，例如 'speed'
    % 也可在命令行里传列序号，例如 2
    defaultSpeedColumn = 'speed';

    % CSV 分隔符
    % 常见情况：
    % ','  -> 普通逗号分隔 CSV
    % ';'  -> 分号分隔
    % ''   -> 让 readtable 自动判断
    defaultDelimiter = ',';

    % 二次模型参数：
    % u = k1 * n^2 + k2 * n + k3
    % 其中：
    % u -> 预测速度
    % n -> PWM
    defaultK1 = -1.52097848e-05;
    defaultK2 = 0.05640098878;
    defaultK3 = -50.37844217;

    %% ======================== 参数整理区 ========================
    % 如果没有传入 csvFile，则先使用输入配置区中的默认文件路径。

    if nargin < 1
        csvFile = '';
    end

    if isempty(csvFile)
        csvFile = defaultCsvFile;
    end

    % 当既没有传入参数、默认文件路径又为空时，可选择弹窗选文件。
    if isempty(csvFile)
        scriptDir = fileparts(mfilename('fullpath'));
        defaultFolder = scriptDir;

        if useFileDialogWhenCsvFileEmpty
            try
                [selectedFile, selectedFolder] = uigetfile( ...
                    {'*.csv', 'CSV Files (*.csv)'; '*.*', 'All Files (*.*)'}, ...
                    '选择一个 PWM-Speed CSV 文件', ...
                    defaultFolder);
            catch
                selectedFile = 0;
                selectedFolder = '';
            end

            if isequal(selectedFile, 0)
                error(['当前未提供 CSV 文件。你可以：', newline, ...
                    '1. 直接修改输入配置区中的 defaultCsvFile；', newline, ...
                    '2. 在命令行中调用 compare_speed_pwm_csv_model(''your_file.csv'')；', newline, ...
                    '3. 或者重新运行并在弹窗中选择文件。']);
            end

            csvFile = fullfile(selectedFolder, selectedFile);
        else
            error('当前未指定 CSV 文件，请修改输入配置区中的 defaultCsvFile。');
        end
    end

    parser = inputParser;
    parser.addRequired('csvFile', @(x) ischar(x) || isstring(x));
    parser.addParameter('PwmColumn', defaultPwmColumn, @(x) isnumeric(x) || ischar(x) || isstring(x));
    parser.addParameter('SpeedColumn', defaultSpeedColumn, @(x) isnumeric(x) || ischar(x) || isstring(x));
    parser.addParameter('Delimiter', defaultDelimiter, @(x) ischar(x) || isstring(x));
    parser.addParameter('K1', defaultK1, @(x) isnumeric(x) && isscalar(x));
    parser.addParameter('K2', defaultK2, @(x) isnumeric(x) && isscalar(x));
    parser.addParameter('K3', defaultK3, @(x) isnumeric(x) && isscalar(x));
    parser.parse(csvFile, varargin{:});
    cfg = parser.Results;

    %% ======================== CSV 读取区 ========================
    % 1. 先解析 CSV 文件路径
    % 2. 再用 readtable 读取表格
    % 3. 后续再从表格中提取 PWM 列和速度列

    scriptDir = fileparts(mfilename('fullpath'));
    csvFile = resolveInputPath(char(string(cfg.csvFile)), scriptDir);

    if ~isfile(csvFile)
        error('找不到 CSV 文件：%s', csvFile);
    end

    try
        if strlength(string(cfg.Delimiter)) == 0
            tbl = readtable(csvFile);
        else
            tbl = readtable(csvFile, 'Delimiter', char(string(cfg.Delimiter)));
        end
    catch readErr
        error('读取 CSV 文件失败：%s\n原因：%s', csvFile, readErr.message);
    end

    %% ======================== 数据提取与整理区 ========================
    % 1. 从表格中提取 PWM 列和速度列
    % 2. 转为数值列向量
    % 3. 删除无效行（如空值、NaN、非数值）
    % 4. 按 PWM 从小到大排序
    % 5. 对重复 PWM 求平均，得到“实测曲线”

    [rawPwm, pwmColumnName] = extractFlexibleColumn(tbl, cfg.PwmColumn, {'pwm', 'n'});
    [rawSpeed, speedColumnName] = extractFlexibleColumn(tbl, cfg.SpeedColumn, {'speed', 'speed_mps', 'u'});

    rawPwm = ensureColumn(rawPwm);
    rawSpeed = ensureColumn(rawSpeed);

    validMask = isfinite(rawPwm) & isfinite(rawSpeed);
    removedCount = sum(~validMask);
    rawPwm = rawPwm(validMask);
    rawSpeed = rawSpeed(validMask);

    if isempty(rawPwm)
        error('在文件 "%s" 中没有找到有效的数值型 PWM/速度数据。', csvFile);
    end

    [rawPwm, sortIdx] = sort(rawPwm);
    rawSpeed = rawSpeed(sortIdx);

    [curvePwm, ~, groupIndex] = unique(rawPwm, 'sorted');
    curveSpeed = accumarray(groupIndex, rawSpeed, [], @mean);
    repeatCount = accumarray(groupIndex, 1, [], @sum);

    %% ======================== 模型计算区 ========================
    % 使用给定的二次模型：
    %   u = k1 * n^2 + k2 * n + k3
    % 分别计算：
    % 1. 每个原始采样点上的模型值
    % 2. 每个唯一 PWM 点上的模型值
    % 3. 实测曲线与模型曲线之间的误差

    modelCoeff = [cfg.K1, cfg.K2, cfg.K3];
    modelSpeedRaw = polyval(modelCoeff, rawPwm);
    modelSpeedCurve = polyval(modelCoeff, curvePwm);
    curveError = curveSpeed - modelSpeedCurve;

    rmseValue = sqrt(mean(curveError .^ 2));
    maeValue = mean(abs(curveError));
    maxAbsError = max(abs(curveError));

    xFit = linspace(min(curvePwm), max(curvePwm), 300).';
    yFit = polyval(modelCoeff, xFit);

    actualDataColor = [74, 35, 120] / 255;
    actualLineColor = [170, 160, 196] / 255;
    fitLineColor = [0.82, 0.10, 0.10];
    steadyScatterSize = 24;
    fitLineWidth = 1.4;
    lineWidth = 1.1;
    pointMarkerSize = 9;

    %% ======================== 图 1：实测数据与模型对比图 ========================

    comparisonFigure = figure('Name', '实测与模型 PWM-Speed 对比', 'Color', 'w');
    hold on;
    applyThesisAxesStyle();
    scatter(rawPwm, rawSpeed, steadyScatterSize, 'o', ...
        'MarkerFaceColor', actualDataColor, ...
        'MarkerEdgeColor', actualDataColor, ...
        'LineWidth', 0.6, ...
        'DisplayName', 'CSV 实测数据');
    plot(xFit, yFit, '-', 'Color', fitLineColor, 'LineWidth', fitLineWidth, ...
        'DisplayName', '识别模型');
    xlabel('PWM 指令 (PWM)');
    ylabel('纵向速度 (m/s)');
    legend('Location', 'best');
    hold off;

    %% ======================== 图 2：误差图 ========================

    errorFigure = figure('Name', 'PWM-Speed 误差图', 'Color', 'w');
    hold on;
    plot(curvePwm, curveError, '-', 'Color', actualLineColor, 'LineWidth', lineWidth, ...
        'HandleVisibility', 'off');
    plot(curvePwm, curveError, '.', 'Color', actualDataColor, 'MarkerSize', pointMarkerSize, ...
        'DisplayName', '实测曲线 - 识别模型');
    yline(0, '--', 'Color', [0.35, 0.35, 0.35], 'LineWidth', 1.0, 'HandleVisibility', 'off');
    applyThesisAxesStyle();
    xlabel('PWM 指令 (PWM)');
    ylabel('速度误差 (m/s)');
    currentLowerLimit = min([curveError(:); 0]);
    ylim([currentLowerLimit, 1]);
    legend('Location', 'best');
    hold off;

    %% ======================== 命令行输出区 ========================

    fprintf('CSV 文件：%s\n', csvFile);
    fprintf('PWM 列：%s\n', pwmColumnName);
    fprintf('速度列：%s\n', speedColumnName);
    fprintf('有效样本数：%d\n', numel(rawPwm));
    fprintf('唯一 PWM 数量：%d\n', numel(curvePwm));
    if removedCount > 0
        fprintf('已删除无效行数：%d\n', removedCount);
    end
    fprintf('模型：u = %.10g*n^2 + %.10g*n + %.10g\n', cfg.K1, cfg.K2, cfg.K3);
    fprintf('RMSE = %.6f m/s\n', rmseValue);
    fprintf('MAE = %.6f m/s\n', maeValue);
    fprintf('最大绝对误差 = %.6f m/s\n', maxAbsError);

    repeatedPwmMask = repeatCount > 1;
    if any(repeatedPwmMask)
        fprintf('说明：存在重复 PWM，误差计算前已先对同一 PWM 的速度取平均。\n');
    end

    result = struct();
    result.csvFile = csvFile;
    result.pwmColumn = pwmColumnName;
    result.speedColumn = speedColumnName;
    result.rawPwm = rawPwm;
    result.rawSpeed = rawSpeed;
    result.modelSpeedRaw = modelSpeedRaw;
    result.curvePwm = curvePwm;
    result.curveSpeed = curveSpeed;
    result.modelSpeedCurve = modelSpeedCurve;
    result.curveError = curveError;
    result.repeatCount = repeatCount;
    result.coeff = modelCoeff;
    result.rmse = rmseValue;
    result.mae = maeValue;
    result.maxAbsError = maxAbsError;
    result.comparisonFigure = comparisonFigure;
    result.errorFigure = errorFigure;
end

function resolvedPath = resolveInputPath(inputPath, scriptDir)
% 解析输入路径。
% 优先判断当前给定路径是否存在；
% 若不存在，则再尝试相对于脚本所在目录进行拼接。

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
% 将输入数据转换为数值列向量。

    values = convertColumnToNumeric(values);
    values = values(:);
end

function [values, matchedName] = extractFlexibleColumn(tbl, columnSpec, fallbackNames)
% 从表格中提取目标列。
% 支持两种方式：
% 1. 按列序号提取
% 2. 按列名提取，并允许使用候选列名回退匹配

    if isnumeric(columnSpec)
        columnIndex = round(columnSpec);
        if columnIndex < 1 || columnIndex > size(tbl, 2)
            error('列序号 %d 超出了表格列数范围。', columnIndex);
        end
        values = tbl{:, columnIndex};
        values = convertColumnToNumeric(values);
        matchedName = tbl.Properties.VariableNames{columnIndex};
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
            matchedName = variableNames{matchedIndex};
            return;
        end
    end

    error('在 CSV 文件中找不到列 "%s"。', requestedName);
end

function matchedIndex = matchColumnName(variableNames, requestedName)
% 匹配表格列名。
% 匹配顺序为：
% 1. 完全匹配
% 2. 忽略大小写匹配
% 3. 使用 matlab 合法变量名规则后再匹配

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
% 支持单元格、字符串、字符数组、逻辑量等常见输入形式。

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
        error('所选 CSV 列无法转换为数值类型。');
    end
end

function applyThesisAxesStyle()
% 统一坐标轴样式，尽量与 plot_pwm_speed_analysis.m 保持一致。

    grid on;
    box on;
    ax = gca;
    ax.LineWidth = 0.9;
    ax.FontSize = 11;
    ax.FontName = 'SimSun';
    ax.XLabel.FontName = 'SimSun';
    ax.YLabel.FontName = 'SimSun';
    ax.ZLabel.FontName = 'SimSun';
end
