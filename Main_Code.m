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
% NumHeaderLines=21: skip the first 21 non-data header rows
% VariableNamingRule='preserve': retain original column names (including spaces/special chars)

V12 = double(T.("Wind spee"));         % wind speed at 12 m

% Raw data quality check
num_nan_raw = sum(isnan(V12));      % Count NaN (missing) values
total_data_points = numel(V12);     % Total number of data points

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
V12(~isfinite(V12)) = NaN;    % Mark Inf, -Inf and other non-finite values as NaN
V12(V12 < 0) = NaN;           % Negative wind speeds are invalid, mark as NaN
V12 = fillmissing(V12, 'linear');   % Fill NaN gaps using linear interpolation

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

Pwind = zeros(size(V125));  % Initialise wind power array (MW)
idx_ramp  = (V125 >= Vci) & (V125 < Vr);  % Indices for ramp-up region
idx_rated = (V125 >= Vr)  & (V125 < Vco);  % Indices for rated region

Pwind(idx_ramp)  = Pr * ((V125(idx_ramp).^3 - Vci^3) ./ (Vr^3 - Vci^3));
Pwind(idx_rated) = Pr;

Pwind = Pwind(:);  % Ensure column vector
N = numel(Pwind);  % Total number of time steps

%% =======================
% 3) BESS and control settings
dt = 0.25;                    % hours (15-min)
MA_Window = 6;                % 6 x 15 min = 1.5 h 
Ebatt_range = 0:1.5:15;       % MWh

Crate = 0.5;                  % 0.5C = 2-hour battery
efficiency_c = 0.95;          % Charging efficiency 
efficiency_d = 0.95;          % Discharging efficiency

SOCmin = 0.2;    % SOC lower bound
SOCmax = 0.8;    % SOC upper bound
SOClow = 0.4;    % SOC low threshold
SOChigh = 0.6;   % SOC high threshold
SOC0 = 0.5;      % Initial SOC

Plim_ratio = 0.85;      
Plim = Plim_ratio * Pr;   % Export limit
clamp_export = @(P) max(0, min(P, Plim));  % clamp_export: anonymous function that clamps power to [0, Plim]

% Moving-average targets
% Case 1 target: causal (backward-looking) moving average of raw wind power [Equation (10)]
Ptarget_out = movmean(Pwind, [MA_Window-1, 0], 'omitnan'); 
% Case 2 target: first clip wind power at Plim, then compute moving average [Equation (11)]
Pwind_capped = min(Pwind, Plim);
Ptarget_exp = movmean(Pwind_capped, [MA_Window-1, 0], 'omitnan');

%% =======================
% 4) Baselines
%% =======================
Pbase_out = Pwind;                % No BESS, no export limit = raw wind power
Pbase_exp = clamp_export(Pwind);  % No BESS, with export limit = clamped power
Pout_only_clipping = min(Pwind, Plim);  % Clipping only, same as Pbase_exp, named separately for comparison

dP_base_out = diff(Pbase_out);   % Case 1 baseline ramps
dP_base_exp = diff(Pbase_exp);   % Case 2 baseline ramps
dP_case3    = diff(Pout_only_clipping);   % Clipping-only (no BESS) ramps
dP_raw      = diff(Pwind);       % Raw wind power ramps

SD_base_out = std(dP_base_out, 'omitnan');    % Case 1 baseline ramp std dev
SD_base_exp = std(dP_base_exp, 'omitnan');    % Case 2 baseline ramp std dev
SD_case3    = std(dP_case3,    'omitnan');    % Clipping-only ramp std dev
SD_raw      = std(dP_raw,      'omitnan');    % Raw wind ramp std dev

Ramp95_raw   = quantile(abs(dP_raw),   0.95);   % Raw wind: 95th-percentile |dP|
Ramp95_case3 = quantile(abs(dP_case3), 0.95);   % Clipping-only: 95th-percentile |dP|
Ramp99_raw   = quantile(abs(dP_raw),   0.99);   % Raw wind: 99th-percentile |dP|
Ramp99_case3 = quantile(abs(dP_case3), 0.99);   % Clipping-only: 99th-percentile |dP|

% Smoothing rate SR = 1 - sigma(dP_smoothed) / sigma(dP_baseline) [Equation (26)]
SR_raw   = 1 - (SD_raw   / max(SD_base_out, 1e-12));  % Raw wind SR
SR_case3 = 1 - (SD_case3 / max(SD_base_out, 1e-12));  % Clipping-only SR

%% =======================
% 5) Economic assumptions
StrikePrice = 72.24;        % GBP/MWh        
Life_Years = 25;
Discount_Rate = 0.058;
disc = (1 + Discount_Rate).^(1:Life_Years);    % disc(k) = (1+r)^k, used to discount year-k cash flows to year 0

Capex_Turbine_MW   = 1250000;       
Opex_Turbine_MW_yr = 20000;         
Capex_Batt_MWh     = 155000;        
Opex_Batt_MWh_yr   = 4000;          
Batt_Replacement_Years = [10 20];

%% =======================
% 6) Allocate result arrays
nE = numel(Ebatt_range);     % Number of battery capacity sweep points

SD_out_abs = zeros(nE,1);    % Case 1 (no export limit) ramp std dev
SD_exp_abs = zeros(nE,1);    % Case 2 (with export limit) ramp std dev

SR_out = zeros(nE,1);        % Case 1 smoothing rate
SR_exp = zeros(nE,1);        % Case 2 smoothing rate
DeltaSR_out = nan(nE,1);     % Case 1 marginal relative change in SR from previous capacity
DeltaSR_exp = nan(nE,1);     % Case 2 marginal relative change in SR 

Ramp95_out = zeros(nE,1);    % Case 1: 95th-percentile ramp
Ramp95_exp = zeros(nE,1);    % Case 2: 95th-percentile ramp

Ramp99_out = zeros(nE,1);    % Case 1: 99th-percentile ramp
Ramp99_exp = zeros(nE,1);    % Case 2: 99th-percentile ramp

% Economic metric arrays (with export limit)
Export_MWh = zeros(nE,1);     % Exported energy (MWh)
Curt_MWh   = zeros(nE,1);     % Curtailed energy (MWh)
AnnualRevenue_Pound = zeros(nE,1);    % Annual revenue (GBP)
NPV_MPound = zeros(nE,1);     % Net present value (MGBP)

% Economic metric arrays (without export limit)
Export_MWh_out = zeros(nE,1);
Curt_MWh_out   = zeros(nE,1);
AnnualRevenue_Pound_out = zeros(nE,1);
NPV_MPound_out = zeros(nE,1);

%% =======================
% 7) Main loop over battery size
Ebatt_validate = 6;    % Battery capacity used for detailed validation plots (MWh)

for i = 1:nE
    Ebatt = Ebatt_range(i);      % Current battery capacity (MWh)
    Pcmax = Crate * Ebatt;       % Max charging power (MW) [Eq. (6)]
    Pdmax = Crate * Ebatt;       % Max discharging power (MW) [Eq. (6)]

    SOC_out = zeros(N,1); SOC_out(1) = SOC0;    % Case 1 SOC sequence
    SOC_exp = zeros(N,1); SOC_exp(1) = SOC0;    % Case 2 SOC sequence

    Pbatt_out_act = zeros(N,1);    % Case 1 actual battery charge/discharge power
    Pbatt_exp_act = zeros(N,1);    % Case 2 actual battery charge/discharge power

    Pout_final = zeros(N,1);      % Case 1 final output power
    Pexp_final = zeros(N,1);      % Case 2 final exported power
    Pout2_raw  = zeros(N,1);      % Case 2 output power before export clipping
  
    for t = 1:N
        % Retrieve previous time step SOC
        if t == 1
            SOC_prev_out = SOC0;
            SOC_prev_exp = SOC0;
        else
            SOC_prev_out = SOC_out(t-1);
            SOC_prev_exp = SOC_exp(t-1);
        end

        % -------- Case 1: BESS without export limit --------
        % Deviation signal = actual wind power - moving average target [Eq. (12)]
        % Positive: charge battery, Negative: discharge battery
        Praw_out = Pwind(t) - Ptarget_out(t);

        if Praw_out > 0
            X_out = X_charge(SOC_prev_out, SOChigh, SOCmax);
            % When SOC is high, reduce charging to prevent overcharge [Eq. (15)]
        elseif Praw_out < 0
            X_out = X_disch(SOC_prev_out, SOCmin, SOClow);
            % When SOC is low, reduce discharging to prevent over-discharge [Eq. (14)]
        else
            X_out = 0;
        end

        % Commanded battery power = deviation * (1 - X^3) [Equation (16)]
        Pbatt_cmd_out = Praw_out * (1 - X_out^3);

        % Call physical SOC update function, accounting for efficiency, power limits, and SOC boundaries [Eqs. (4), (17), (18), (19)]
        [Pbatt_out_act(t), SOC_out(t), ~, ~] = ...
            update_soc_physics(SOC_prev_out, Pbatt_cmd_out, Ebatt, dt, ...
            efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax, Pdmax);

        % Final output = wind power - actual battery action [Eq. (8)]
        Pout_final(t) = max(0, Pwind(t) - Pbatt_out_act(t));



        % -------- Case 2: BESS with export limit --------
        % First clamp wind power to Plim, then compute deviation signal [Eq. (13)]
        Praw_exp = min(Pwind(t), Plim) - Ptarget_exp(t);

        if Praw_exp > 0
            X_exp = X_charge(SOC_prev_exp, SOChigh, SOCmax);
        elseif Praw_exp < 0
            X_exp = X_disch(SOC_prev_exp, SOCmin, SOClow);
        else
            X_exp = 0;
        end

        Pbatt_cmd_exp = Praw_exp * (1 - X_exp^3);  % [Eq. (16)]

        [Pbatt_exp_act(t), SOC_exp(t), ~, ~] = ...
            update_soc_physics(SOC_prev_exp, Pbatt_cmd_exp, Ebatt, dt, ...
            efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax, Pdmax);

        Pout2_raw(t)  = max(0, Pwind(t) - Pbatt_exp_act(t));
        Pexp_final(t) = clamp_export(Pout2_raw(t));

    end

    if abs(Ebatt - Ebatt_validate) < 1e-9
        Pout_validate = Pout_final;
        Pexp_validate = Pexp_final;

    end

    % ---- Compute technical metrics ----
    dP_out = diff(Pout_final);   % Case 1 power ramps [Eq. (25)]
    dP_exp = diff(Pexp_final);   % Case 2 power ramps

    SD_out_abs(i) = std(dP_out, 'omitnan');   % Case 1 ramp std dev (sigma_battery)
    SD_exp_abs(i) = std(dP_exp, 'omitnan');   % Case 2 ramp std dev

    % Smoothing rate: referenced against the respective baseline [Eq. (26)]
    SR_out(i) = 1 - (SD_out_abs(i) / max(SD_base_out, 1e-12));
    SR_exp(i) = 1 - (SD_exp_abs(i) / max(SD_base_exp, 1e-12));

    % Marginal relative change in SR (relative to previous capacity point)
    if i > 1
       DeltaSR_out(i) = (SR_out(i) - SR_out(i-1)) / max(SR_out(i-1), 1e-12);
       DeltaSR_exp(i) = (SR_exp(i) - SR_exp(i-1)) / max(SR_exp(i-1), 1e-12);
    end

    % Extreme ramp percentiles
    Ramp95_out(i) = quantile(abs(dP_out), 0.95);  % 95th-percentile ramp
    Ramp95_exp(i) = quantile(abs(dP_exp), 0.95);
    Ramp99_out(i) = quantile(abs(dP_out), 0.99);  % 99th-percentile ramp
    Ramp99_exp(i) = quantile(abs(dP_exp), 0.99);

    % ---- Economic metrics (with export limit, Case 2) ----
    % Total exported energy = sum(exported power at each step) * time step size
    Export_MWh(i) = sum(Pexp_final) * dt;

    % Curtailed power = output before clipping - exported power [Eq. (23)]
    Pcurt = max(0, Pout2_raw - Pexp_final);
    Curt_MWh(i) = sum(Pcurt) * dt;   


    % Annual revenue = strike price * exported energy [Eqs. (20)-(22) simplified
    AnnualRevenue_Pound(i) = StrikePrice * Export_MWh(i);


    % Initial investment
    Init_Inv = (Pr * Capex_Turbine_MW) + (Ebatt * Capex_Batt_MWh); 
    % Annual operating cost
    Costs_Annual = (Pr * Opex_Turbine_MW_yr) + (Ebatt * Opex_Batt_MWh_yr);  

    % Present value of net operating cash flows = sum[(revenue - cost) / (1+r)^k], k=1..25
    PV_net = sum((AnnualRevenue_Pound(i) - Costs_Annual) ./ disc);
    
    % Present value of battery replacement costs
    PV_repl = 0;
    for ry = Batt_Replacement_Years
        if ry <= Life_Years
            PV_repl = PV_repl + (Ebatt * Capex_Batt_MWh) / ((1 + Discount_Rate)^ry);
        end
    end
    
    % NPV = -initial investment + net operating PV - replacement PV [Eq. (24)]
    NPV_total = -Init_Inv + PV_net - PV_repl;
    NPV_MPound(i) = NPV_total / 1e6;   % Convert to million GBP

    % ---- Economic metrics (without export limit, Case 1) ----
    Export_MWh_out(i) = sum(Pout_final) * dt;
    Curt_MWh_out(i) = 0;        % No curtailment without export limit
    AnnualRevenue_Pound_out(i) = StrikePrice * Export_MWh_out(i);

    Init_Inv_out = (Pr * Capex_Turbine_MW) + (Ebatt * Capex_Batt_MWh);
    Costs_Annual_out = (Pr * Opex_Turbine_MW_yr) + (Ebatt * Opex_Batt_MWh_yr);
    PV_net_out = sum((AnnualRevenue_Pound_out(i) - Costs_Annual_out) ./ disc);

    PV_repl_out = 0;
    for ry = Batt_Replacement_Years
        if ry <= Life_Years
            PV_repl_out = PV_repl_out + (Ebatt * Capex_Batt_MWh) / ((1 + Discount_Rate)^ry);
        end
    end

    NPV_total_out = -Init_Inv_out + PV_net_out - PV_repl_out;
    NPV_MPound_out(i) = NPV_total_out / 1e6;

fprintf(['Ebatt %4.1f | SR(no)=%.3f SR(limit)=%.3f | ' ...
         'dSR(no)=%.4f dSR(limit)=%.4f | ' ...
         'P95(no)=%.2f P95(limit)=%.2f | ' ...
         'P99(no)=%.2f P99(limit)=%.2f | NPV=%.3f M£\n'], ...
        Ebatt, SR_out(i), SR_exp(i), ...
        DeltaSR_out(i), DeltaSR_exp(i), ...
        Ramp95_out(i), Ramp95_exp(i), ...
        Ramp99_out(i), Ramp99_exp(i), NPV_MPound(i));
end

%% =======================
% 8) Technical figures

% --- Figure 1: Smoothing Rate ---
figure('Color','w');
plot(Ebatt_range, SR_out, '-o', 'LineWidth', 2); hold on;
plot(Ebatt_range, SR_exp, '-s', 'LineWidth', 2);
yline(SR_raw,   '--k', 'LineWidth', 1.5);
yline(SR_case3, '-.', 'Color', [0.4 0.4 0.4], 'LineWidth', 2);
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('Smoothing Rate, SR', 'FontSize', lblFS, 'FontWeight', 'bold');
legend('BESS (No Limit)', 'BESS + Limit', 'Raw Wind Power', 'Only Limit (No BESS)', ...
    'Location', 'best', 'FontSize', lgdFS);
title('Smoothing Rate vs Battery Capacity', 'FontSize', ttlFS, 'FontWeight', 'bold');
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% --- Figure 2: 95th Percentile Ramp ---
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
title('95th-Percentile Ramp vs Battery Capacity', 'FontSize', ttlFS, 'FontWeight', 'bold');
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% --- Figure 3: 99th Percentile Ramp ---
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
title('99th-Percentile Ramp vs Battery Capacity', 'FontSize', ttlFS, 'FontWeight', 'bold');
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% --- Figure 4: Std Dev of Delta P ---
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
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

%% =======================
% 9) Economic figures
%% =======================

% --- Figure 5: NPV ---
figure('Color','w');
plot(Ebatt_range, NPV_MPound_out, '-o', 'LineWidth', 2); hold on;
plot(Ebatt_range, NPV_MPound, '-s', 'LineWidth', 2);
grid on;
xlabel('Battery Capacity (MWh)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('NPV (M£)', 'FontSize', lblFS, 'FontWeight', 'bold');
title('NPV vs Battery Capacity', 'FontSize', ttlFS, 'FontWeight', 'bold');
legend('No Export Limit', 'With Export Limit (0.85P_r)', ...
    'Location', 'best', 'FontSize', lgdFS);
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');


%% =======================
% 10) Results table
%% =======================
results = table( ...
    Ebatt_range(:), ...
    SR_out, Ramp95_out, Ramp99_out, ...
    SR_exp, Ramp95_exp, Ramp99_exp, ...
    Export_MWh, Curt_MWh, AnnualRevenue_Pound, NPV_MPound, ...
    Export_MWh_out, AnnualRevenue_Pound_out, NPV_MPound_out, ...
    'VariableNames', { ...
        'Ebatt_MWh', ...
        'SR_noGrid', 'P95_noGrid', 'P99_noGrid', ...
        'SR_withGrid', 'P95_withGrid', 'P99_withGrid', ...
        'Export_MWh', 'Curt_MWh', 'AnnualRevenue_GBP', 'NPV_MGBP', ...
        'Export_MWh_noLimit', 'AnnualRevenue_noLimit', 'NPV_MGBP_noLimit' ...
    } ...
);
disp(results);

%% =======================
% 11) Validation Figure 1:
%     Tail distribution of ramp magnitude

dP_no_val  = diff(Pout_validate);
dP_lim_val = diff(Pexp_validate);

thr95_no  = quantile(abs(dP_no_val),  0.95);
thr95_lim = quantile(abs(dP_lim_val), 0.95);
thr99_no  = quantile(abs(dP_no_val),  0.99);
thr99_lim = quantile(abs(dP_lim_val), 0.99);

[r_no, ~]  = sort(abs(dP_no_val), 'ascend');
[r_lim, ~] = sort(abs(dP_lim_val), 'ascend');

n1 = numel(r_no);
n2 = numel(r_lim);

ccdf_no  = (n1:-1:1)' / n1;
ccdf_lim = (n2:-1:1)' / n2;

figure('Color','w');
semilogy(r_no,  ccdf_no,  'b', 'LineWidth', 2); hold on;
semilogy(r_lim, ccdf_lim, 'g', 'LineWidth', 2);

xline(thr95_no,  'b--', '95% no limit',   'LineWidth', 2.0, 'FontSize', axFS, 'FontWeight', 'bold');
xline(thr95_lim, 'g--', '95% with limit', 'LineWidth', 2.0, 'FontSize', axFS, 'FontWeight', 'bold', 'LabelVerticalAlignment', 'middle', 'LabelHorizontalAlignment', 'left');
xline(thr99_no,  'b:',  '99% no limit',   'LineWidth', 2.5, 'FontSize', axFS, 'FontWeight', 'bold');
xline(thr99_lim, 'g:',  '99% with limit', 'LineWidth', 2.5, 'FontSize', axFS, 'FontWeight', 'bold');

grid on;
xlabel('| \Delta P | (MW/15 min)', 'FontSize', lblFS, 'FontWeight', 'bold');
ylabel('Exceedance probability P(|\Delta P| > x)', 'FontSize', lblFS, 'FontWeight', 'bold');
legend('BESS (No Limit)', 'BESS + Limit', 'Location', 'southwest', 'FontSize', lgdFS);
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

fprintf('Max |dP| no limit   = %.6f\n', max(abs(dP_no_val)));
fprintf('Max |dP| with limit = %.6f\n', max(abs(dP_lim_val)));
fprintf('Difference          = %.6e\n', ...
    max(abs(dP_no_val)) - max(abs(dP_lim_val)));

% --- Inset plot (also with bold axes) ---
ax_inset = axes('Position', [0.59 0.57 0.3 0.32]);
plot(r_no,  ccdf_no,  'b', 'LineWidth', 1.5); hold on;
plot(r_lim, ccdf_lim, 'g', 'LineWidth', 1.5);
xlim([0 0.4]);
grid on;
xlabel('|\DeltaP|', 'FontSize', 10, 'FontWeight', 'bold');
ylabel('P(|\DeltaP|>x)', 'FontSize', 10, 'FontWeight', 'bold');
title('Linear scale', 'FontSize', 11, 'FontWeight', 'bold');
set(ax_inset, 'LineWidth', 1.5, 'FontSize', 10, 'FontWeight', 'bold');

%% =======================
% 12) Mechanism explanation figure

% --- Find a good window ---
win_len = 30;
score_win = zeros(N - win_len + 1, 1);

for s = 1:(N - win_len + 1)
    seg = Pwind(s:s+win_len-1); 
    above = seg > Plim;                % Whether each point exceeds the export limit
    crossings = sum(abs(diff(above))); % Number of times wind crosses the limit
    frac_above = mean(above);          % Fraction of time above the limit
    score_win(s) = crossings * (1 - abs(frac_above - 0.5));
    % Scoring criterion: high crossings + roughly half the time above/below
    % limit, higher score window will be selected
end

[~, best_start] = max(score_win);      % Start index of highest-scoring window
idx_win = best_start:(best_start + win_len - 1);   % Window indices
t_win = (0:win_len-1) * dt;            % Time axis within window (hours)

% --- Recompute both cases for demo capacity ---
Ebatt_demo = 6;
Pcmax_demo = Crate * Ebatt_demo;   % Max charging power = 3 MW
Pdmax_demo = Crate * Ebatt_demo;   % Max discharging power = 3 MW

target_out_win = Ptarget_out(idx_win);  % Case 1 target (within window)
target_exp_win = Ptarget_exp(idx_win);  % Case 2 target (within window)

Praw_out_win = Pwind(idx_win) - target_out_win;             % Case 1 deviation
Praw_exp_win = min(Pwind(idx_win), Plim) - target_exp_win;  % Case 2 deviation

SOC_demo_out = zeros(win_len,1); SOC_demo_out(1) = SOC0;
SOC_demo_exp = zeros(win_len,1); SOC_demo_exp(1) = SOC0;
Pbatt_demo_out = zeros(win_len,1);
Pbatt_demo_exp = zeros(win_len,1);
Pout_demo_out = zeros(win_len,1);
Pout_demo_exp = zeros(win_len,1);

for tt = 1:win_len
    if tt == 1
        soc_prev_o = SOC0;
        soc_prev_e = SOC0;
    else
        soc_prev_o = SOC_demo_out(tt-1);
        soc_prev_e = SOC_demo_exp(tt-1);
    end

    % Case 1 (unconstrained)
    pr_o = Praw_out_win(tt);
    if pr_o > 0
        X_o = X_charge(soc_prev_o, SOChigh, SOCmax);
    elseif pr_o < 0
        X_o = X_disch(soc_prev_o, SOCmin, SOClow);
    else
        X_o = 0;
    end
    cmd_o = pr_o * (1 - X_o^3);
    [Pbatt_demo_out(tt), SOC_demo_out(tt), ~, ~] = ...
        update_soc_physics(soc_prev_o, cmd_o, Ebatt_demo, dt, ...
        efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax_demo, Pdmax_demo);
    Pout_demo_out(tt) = max(0, Pwind(idx_win(tt)) - Pbatt_demo_out(tt));

    % Case 2 (constrained)
    pr_e = Praw_exp_win(tt);
    if pr_e > 0
        X_e = X_charge(soc_prev_e, SOChigh, SOCmax);
    elseif pr_e < 0
        X_e = X_disch(soc_prev_e, SOCmin, SOClow);
    else
        X_e = 0;
    end
    cmd_e = pr_e * (1 - X_e^3);
    [Pbatt_demo_exp(tt), SOC_demo_exp(tt), ~, ~] = ...
        update_soc_physics(soc_prev_e, cmd_e, Ebatt_demo, dt, ...
        efficiency_c, efficiency_d, SOCmin, SOCmax, Pcmax_demo, Pdmax_demo);
    Pout_demo_exp(tt) = max(0, Pwind(idx_win(tt)) - Pbatt_demo_exp(tt));
end

Pexport_demo = min(Pout_demo_exp, Plim);  % Case 2 final exported power after clipping

% --- Plot ---
figure('Color','w', 'Position', [50 50 900 950]);

% Helper: compute ylim with 5% margin on each side
pad_ylim = @(ydata) [min(ydata) - 0.05*(max(ydata)-min(ydata)), max(ydata) + 0.05*(max(ydata)-min(ydata))];

% (a) Wind power + Plim
subplot(4,1,1);
plot(t_win, Pwind(idx_win), 'k', 'LineWidth', 2); hold on;
yline(Plim, 'r--', 'LineWidth', 1.5);
ylabel('Power (MW)', 'FontSize', lblFS, 'FontWeight', 'bold');
title('(a) Raw Wind Power', 'FontSize', ttlFS, 'FontWeight', 'bold');
legend('P_{wind}', 'P_{lim}', 'Location', 'best', 'FontSize', lgdFS);
grid on; xlim([0 t_win(end)]);
ylim(pad_ylim([Pwind(idx_win); Plim]));
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% (b) Moving average targets
subplot(4,1,2);
plot(t_win, target_out_win, 'b', 'LineWidth', 2); hold on;
plot(t_win, target_exp_win, 'r', 'LineWidth', 2);
ylabel('Power (MW)', 'FontSize', lblFS, 'FontWeight', 'bold');
title('(b) Moving Average Target', 'FontSize', ttlFS, 'FontWeight', 'bold');
legend('Unconstrained target', 'Constrained target (flattened)', ...
    'Location', 'best', 'FontSize', lgdFS);
grid on; xlim([0 t_win(end)]);
ylim(pad_ylim([target_out_win; target_exp_win]));
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% (c) BESS compensation power
subplot(4,1,3);
plot(t_win, Pbatt_demo_out, 'b', 'LineWidth', 2); hold on;
plot(t_win, Pbatt_demo_exp, 'r', 'LineWidth', 2);
yline(0, 'k:', 'LineWidth', 0.8);
ylabel('Power (MW)', 'FontSize', lblFS, 'FontWeight', 'bold');
title('(c) BESS Compensation Power', 'FontSize', ttlFS, 'FontWeight', 'bold');
legend('Unconstrained', 'Constrained', 'Location', 'best', 'FontSize', lgdFS);
grid on; xlim([0 t_win(end)]);
ylim(pad_ylim([Pbatt_demo_out; Pbatt_demo_exp]));
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

% (d) Final output
subplot(4,1,4);
plot(t_win, Pout_demo_out, 'b', 'LineWidth', 2); hold on;
plot(t_win, Pexport_demo, 'r', 'LineWidth', 2);
yline(Plim, 'r--', 'LineWidth', 1.5);
ylabel('Power (MW)', 'FontSize', lblFS, 'FontWeight', 'bold');
xlabel('Time (hours)', 'FontSize', lblFS, 'FontWeight', 'bold');
title('(d) Final Output Power', 'FontSize', ttlFS, 'FontWeight', 'bold');
legend('P_{out} (unconstrained)', 'P_{export} (constrained)', 'P_{lim}', ...
    'Location', 'best', 'FontSize', lgdFS);
grid on; xlim([0 t_win(end)]);
ylim(pad_ylim([Pout_demo_out; Pexport_demo; Plim]));
set(gca, 'LineWidth', axLW, 'FontSize', axFS, 'FontWeight', 'bold');

sgtitle(sprintf('Mechanism: Effect of Clipping in Moving Average Target (%.1f MWh)', Ebatt_demo), ...
    'FontSize', ttlFS+1, 'FontWeight', 'bold');

%% ========================================================================
% Local functions
% [Equation (15)]
function X = X_charge(SOC, SOChigh, SOCmax)
    if SOC <= SOChigh
        X = 0;
    elseif SOC >= SOCmax
        X = 1;
    else
        X = (SOC - SOChigh) / (SOCmax - SOChigh);
    end
end

% [Equation (14)]
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

    % Maximum feasible charging power [Equation (18)]
    Pch_feas = min(Pcmax, ...
        (SOCmax - SOC_prev) * Ebatt_MWh / (efficiency_c * dt_h));
    % the maximum power at which the battery can charge within dt without exceeding SOCmax

    % Maximum feasible discharging power [Equation (19)]
    Pdis_feas = min(Pdmax, ...
        (SOC_prev - SOCmin) * efficiency_d * Ebatt_MWh / dt_h);
    % the maximum power at which the battery can discharge within dt without exceeding SOCmax

    % Clip commanded power to feasible range [Equation (17)]
    Pbatt_exec = min(max(Pbatt_cmd, -Pdis_feas), Pch_feas);

    % Update SOC [Equation (4)]
    if Pbatt_exec >= 0
        SOC_new = SOC_prev + (Pbatt_exec * efficiency_c * dt_h) / Ebatt_MWh;
    else
        SOC_new = SOC_prev - ((-Pbatt_exec) / efficiency_d * dt_h) / Ebatt_MWh;
    end

    % Numerical safety: clamp to [SOCmin, SOCmax]
    SOC_new = min(max(SOC_new, SOCmin), SOCmax);
end