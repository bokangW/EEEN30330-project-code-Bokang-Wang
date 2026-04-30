clear; clc; close all;
dbstop if error

%% =======================
% Global formatting settings

axLW   = 1.8;    % axis line width
axFS   = 13;     % axis tick font size
lblFS  = 14;     % label font size
ttlFS  = 15;     % title font size
lgdFS  = 11;     % legend font size

%% =======================
% 0) Read CSV (15-min data)

csvFile = 'Jan 19 to 20 15 min.csv';   % CSV file
T = readtable(csvFile, 'NumHeaderLines', 21, 'VariableNamingRule', 'preserve');

% Change this if your wind-speed column name is slightly different
V12 = double(T.("Wind spee"));         % wind speed at 12 m

% Raw data quality check
num_nan_raw = sum(isnan(V12));
total_data_points = numel(V12);

fprintf('\n--- Raw Data Quality Check ---\n');
fprintf('Total data points: %d\n', total_data_points);
fprintf('Number of NaN values found: %d\n', num_nan_raw);
if num_nan_raw > 0
    fprintf('Raw data contains missing values.\n');
else
    fprintf('No missing values in raw data.\n');
end
fprintf('-------------------------------\n\n');

% Basic cleaning
V12(~isfinite(V12)) = NaN;
V12(V12 < 0) = NaN;
V12 = fillmissing(V12, 'linear');

%% =======================
% 1) Wind shear to hub height

H1 = 12;      % measurement height (m)
H2 = 125;     % hub height (m)
alpha = 0.3;  % shear exponent

V125 = V12 .* (H2/H1).^alpha;

V12_avg  = mean(V12,  'omitnan');
V125_avg = mean(V125, 'omitnan');

fprintf('--- Wind Resource Assessment ---\n');
fprintf('Average Wind Speed at %.1f m: %.2f m/s\n', H1, V12_avg);
fprintf('Average Wind Speed at %.1f m: %.2f m/s\n', H2, V125_avg);
fprintf('--------------------------------\n\n');

%% =======================
% 2) Wind turbine power curve

Pr  = 6.2;    % rated power (MW)
Vci = 3;      % cut-in speed (m/s)
Vr  = 10.5;   % rated speed (m/s)
Vco = 24;     % cut-out speed (m/s)

Pwind = zeros(size(V125));  % MW
idx_ramp  = (V125 >= Vci) & (V125 < Vr);
idx_rated = (V125 >= Vr)  & (V125 < Vco);

Pwind(idx_ramp)  = Pr * ((V125(idx_ramp).^3 - Vci^3) ./ (Vr^3 - Vci^3));
Pwind(idx_rated) = Pr;

Pwind = Pwind(:);
N = numel(Pwind);

%% =======================
% 3) BESS and control settings

dt = 0.25;                    % hours (15-min)
MA_Window = 6;                % 6 x 15 min = 1.5 h causal moving average
Ebatt_range = 0:1.5:15;       % MWh

Crate = 0.5;                  % 0.5C = 2-hour battery
efficiency_c = 0.95;
efficiency_d = 0.95;

SOCmin = 0.2;
SOCmax = 0.8;
SOClow = 0.4;
SOChigh = 0.6;
SOC0 = 0.5;

Plim_ratio = 0.85;
Plim = Plim_ratio * Pr; % export limit
clamp_export = @(P) max(0, min(P, Plim));

% Moving-average targets
% BOTH cases use the SAME target based on raw wind power (clipping NOT in target)
Ptarget_out = movmean(Pwind, [MA_Window-1, 0], 'omitnan');
Ptarget_exp = movmean(Pwind, [MA_Window-1, 0], 'omitnan');  

%% =======================
% 4) Baselines

Pbase_out = Pwind;
Pbase_exp = clamp_export(Pwind);
Pout_only_clipping = min(Pwind, Plim);

dP_base_out = diff(Pbase_out);
dP_base_exp = diff(Pbase_exp);
dP_case3    = diff(Pout_only_clipping);
dP_raw      = diff(Pwind);

SD_base_out = std(dP_base_out, 'omitnan');
SD_base_exp = std(dP_base_exp, 'omitnan');
SD_case3    = std(dP_case3,    'omitnan');
SD_raw      = std(dP_raw,      'omitnan');

Ramp95_raw   = quantile(abs(dP_raw),   0.95);
Ramp95_case3 = quantile(abs(dP_case3), 0.95);
Ramp99_raw   = quantile(abs(dP_raw),   0.99);
Ramp99_case3 = quantile(abs(dP_case3), 0.99);

%% =======================
% 5) Allocate result arrays

nE = numel(Ebatt_range);

SD_out_abs = zeros(nE,1);
SD_exp_abs = zeros(nE,1);

Ramp95_out = zeros(nE,1);
Ramp95_exp = zeros(nE,1);

Ramp99_out = zeros(nE,1);
Ramp99_exp = zeros(nE,1);

%% =======================
% 6) Main loop over battery size

for i = 1:nE
    Ebatt = Ebatt_range(i);
    Pcmax = Crate * Ebatt;
    Pdmax = Crate * Ebatt;

    % State tracking
    SOC_out = zeros(N,1); SOC_out(1) = SOC0;
    SOC_exp = zeros(N,1); SOC_exp(1) = SOC0;

    Pbatt_out_act = zeros(N,1);
    Pbatt_exp_act = zeros(N,1);

    Pout_final = zeros(N,1);
    Pexp_final = zeros(N,1);
    Pout2_raw  = zeros(N,1);

    for t = 1:N
        if t == 1
            SOC_prev_out = SOC0;
            SOC_prev_exp = SOC0;
        else
            SOC_prev_out = SOC_out(t-1);
            SOC_prev_exp = SOC_exp(t-1);
        end

        % -------- Case 1: BESS without export limit --------
        Praw_out = Pwind(t) - Ptarget_out(t);

        if Praw_out > 0
            X_out = X_charge(SOC_prev_out, SOChigh, SOCmax);
        elseif Praw_out < 0
            X_out = X_disch(SOC_prev_out, SOCmin, SOClow);
        else
            X_out = 0;
        end

        Pbatt_cmd_out = Praw_out * (1 - X_out^3);

        [Pbatt_out_act(t), SOC_out(t), ~, ~] = ...
            update_soc_physics(SOC_prev_out, Pbatt_cmd_out, Ebatt, dt, ...
            efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax, Pdmax);

        Pout_final(t) = max(0, Pwind(t) - Pbatt_out_act(t));

        % -------- Case 2: BESS with export limit (clipping at output only) --------
        % KEY DIFFERENCE: raw compensation uses Pwind, not min(Pwind, Plim)
        Praw_exp = Pwind(t) - Ptarget_exp(t);

        if Praw_exp > 0
            X_exp = X_charge(SOC_prev_exp, SOChigh, SOCmax);
        elseif Praw_exp < 0
            X_exp = X_disch(SOC_prev_exp, SOCmin, SOClow);
        else
            X_exp = 0;
        end

        Pbatt_cmd_exp = Praw_exp * (1 - X_exp^3);

        [Pbatt_exp_act(t), SOC_exp(t), ~, ~] = ...
            update_soc_physics(SOC_prev_exp, Pbatt_cmd_exp, Ebatt, dt, ...
            efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax, Pdmax);

        Pout2_raw(t)  = max(0, Pwind(t) - Pbatt_exp_act(t));
        Pexp_final(t) = clamp_export(Pout2_raw(t));  % clipping only here
    end

    % ---- Technical metrics ----
    dP_out = diff(Pout_final);
    dP_exp = diff(Pexp_final);

    SD_out_abs(i) = std(dP_out, 'omitnan');
    SD_exp_abs(i) = std(dP_exp, 'omitnan');

    Ramp95_out(i) = quantile(abs(dP_out), 0.95);
    Ramp95_exp(i) = quantile(abs(dP_exp), 0.95);

    Ramp99_out(i) = quantile(abs(dP_out), 0.99);
    Ramp99_exp(i) = quantile(abs(dP_exp), 0.99);

    fprintf(['Ebatt %4.1f | STD(no)=%.3f STD(limit)=%.3f | ' ...
         'P95(no)=%.3f P95(limit)=%.3f | ' ...
         'P99(no)=%.3f P99(limit)=%.3f\n'], ...
        Ebatt, SD_out_abs(i), SD_exp_abs(i), ...
        Ramp95_out(i), Ramp95_exp(i), ...
        Ramp99_out(i), Ramp99_exp(i));
end

%% =======================
% 7) Technical figures

% --- Figure 1: 95th Percentile Ramp ---
figure('Color','w');
plot(Ebatt_range, Ramp95_out, '-o', 'LineWidth', 2); hold on;
plot(Ebatt_range, Ramp95_exp, '-s', 'LineWidth', 2);
yline(Ramp95_raw,   '--k', 'LineWidth', 1.5);
yline(Ramp95_case3, '-.', 'Color', [0.4 0.4 0.4], 'LineWidth', 2);
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('95th Percentile |\DeltaP| (MW/15 min)', 'FontSize', lblFS, 'FontWeight', 'bold');
legend('BESS (No Limit)', 'BESS + Limit', 'Raw Wind Power', 'Only Limit (No BESS)', ...
    'Location', 'best', 'FontSize', lgdFS);
title('95th-Percentile Ramp vs Battery Capacity (Clipping at Output Only)', ...
    'FontSize', ttlFS, 'FontWeight', 'bold');
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% --- Figure 2: 99th Percentile Ramp ---
figure('Color','w');
plot(Ebatt_range, Ramp99_out, '-o', 'LineWidth', 2); hold on;
plot(Ebatt_range, Ramp99_exp, '-s', 'LineWidth', 2);
yline(Ramp99_raw,   '--k', 'LineWidth', 1.5);
yline(Ramp99_case3, '-.', 'Color', [0.4 0.4 0.4], 'LineWidth', 2);
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('99th Percentile |\DeltaP| (MW/15 min)', 'FontSize', lblFS, 'FontWeight', 'bold');
legend('BESS (No Limit)', 'BESS + Limit', 'Raw Wind Power', 'Only Limit (No BESS)', ...
    'Location', 'best', 'FontSize', lgdFS);
title('99th-Percentile Ramp vs Battery Capacity (Clipping at Output Only)', ...
    'FontSize', ttlFS, 'FontWeight', 'bold');
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% --- Figure 3: Std Dev of Delta P ---
figure('Color','w');
plot(Ebatt_range, SD_out_abs, '-o', 'LineWidth', 2); hold on;
plot(Ebatt_range, SD_exp_abs, '-s', 'LineWidth', 2);
yline(SD_base_out, '--k', 'LineWidth', 1.5);
yline(SD_case3, '-.', 'Color', [0.4 0.4 0.4], 'LineWidth', 2);
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('Standard Deviation of \Delta P (MW/15 min)', 'FontSize', lblFS, 'FontWeight', 'bold');
legend('BESS (No Limit)', 'BESS + Limit', 'Raw Wind Power', 'Only Limit (No BESS)', ...
    'Location', 'best', 'FontSize', lgdFS);
title('Standard Deviation of Ramp vs Battery Capacity (Clipping at Output Only)', ...
    'FontSize', ttlFS, 'FontWeight', 'bold');
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

%% =======================
% 8) Results table

results = table( ...
    Ebatt_range(:), ...
    SD_out_abs, SD_exp_abs, ...
    Ramp95_out, Ramp95_exp, ...
    Ramp99_out, Ramp99_exp, ...
    'VariableNames', { ...
        'Ebatt_MWh', ...
        'STD_noGrid', 'STD_withGrid', ...
        'P95_noGrid', 'P95_withGrid', ...
        'P99_noGrid', 'P99_withGrid' ...
    } ...
);

disp(results);

%% ========================================================================
% Local functions

function X = X_charge(SOC, SOChigh, SOCmax)
    if SOC <= SOChigh
        X = 0;
    elseif SOC >= SOCmax
        X = 1;
    else
        X = (SOC - SOChigh) / (SOCmax - SOChigh);
    end
end

function X = X_disch(SOC, SOCmin, SOClow)
    if SOC >= SOClow
        X = 0;
    elseif SOC <= SOCmin
        X = 1;
    else
        X = (SOClow - SOC) / (SOClow - SOCmin);
    end
end

function [Pbatt_exec, SOC_new, Pch_feas, Pdis_feas] = update_soc_physics( ...
    SOC_prev, Pbatt_cmd, Ebatt_MWh, dt_h, efficiency_c, efficiency_d, ...
    SOCmin, SOCmax, Pcmax, Pdmax)

    if Ebatt_MWh == 0
        Pbatt_exec = 0;
        SOC_new = SOC_prev;
        Pch_feas = 0;
        Pdis_feas = 0;
        return;
    end

    Pch_feas = min(Pcmax, ...
        (SOCmax - SOC_prev) * Ebatt_MWh / (efficiency_c * dt_h));

    Pdis_feas = min(Pdmax, ...
        (SOC_prev - SOCmin) * efficiency_d * Ebatt_MWh / dt_h);

    Pbatt_exec = min(max(Pbatt_cmd, -Pdis_feas), Pch_feas);

    if Pbatt_exec >= 0
        SOC_new = SOC_prev + (Pbatt_exec * efficiency_c * dt_h) / Ebatt_MWh;
    else
        SOC_new = SOC_prev - ((-Pbatt_exec) / efficiency_d * dt_h) / Ebatt_MWh;
    end

    SOC_new = min(max(SOC_new, SOCmin), SOCmax);
end