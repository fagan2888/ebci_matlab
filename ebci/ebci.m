function [thetahat, ci, w_estim, normlng, mu2, kappa, delta] = ebci(Y, X, sigma, alpha, varargin)

    % Empirical Bayes confidence interval (EBCI)
    % i.  Parametric EBCI, or
    % ii. Robust EBCI
    
    % Cite: Armstrong, Timothy B., Michal Koles�r, and Mikkel
    % Plagborg-M�ller (2020), "Robust Empirical Bayes Confidence Intervals"
    
    % Performs either shrinkage under moment independence or t-statistic shrinkage
    % Performs either MSE-optimal shrinkage or length-optimal shrinkage
    
    % Model: Y_i ~ N(theta_i, sigma_i^2)
    
    % EB estimator shrinks Y_i toward X_i'*hat{delta}.
    % In case of t-statistic shrinkage, we shrink Y_i/sigma_i toward X_i'*delta.
    % Shrinkage factor and robust critical value computed from estimated
    % moments of epsilon_i = (theta_i - X_i'*delta).
    % In case of t-statistic shrinkage, epsilon_i = (theta_i/sigma_i - X_i'*delta).
    
    
    % Required inputs:
    % Y             n x 1       preliminary estimates of theta_i
    % X             n x k       matrix of regressors for shrinkage (may include constant column), set to [] if shrinkage toward 0
    % sigma         n x 1       standard deviations of Y_i, conditional on theta_i
    % alpha         1 x 1       significance level
    
    % Optional inputs, specified as pairs of parameter name and value:
    % mu2           1 x 1       value used for mu_2, set to [] if moment should be estimated (default)
    % kappa         1 x 1       value used for kappa (also requires mu2 to be specified), set to [] if moment should be estimated (default)
    % weights       n x 1       weights for estimating delta, mu_2, and kappa; set to [] if equal weights (default)
    % param         bool        true = compute parametric EBCI, false = compute robust EBCI (default)
    % tstat         bool        true = t-statistic shrinkage, false = baseline shrinkage assuming moment independence (default)
    % w_opt         bool        true = length-optimal shrinkage w_opt, false = MSE-optimal shrinkage w_EB (default)
    % use_kappa     bool        true = impose estimated kurtosis bound (default), false = do not impose kurtosis bound
    % fs_correction char        'none' = no finite-sample moment correction (not recommended),
    %                           'PMT' = posterior mean truncation (default), 'FPLIB' = flat prior limited information Bayes
    % verbose       bool        true = show progress when computing EBCI for each observation, false = do not show progress (default)
    % opt_struct    struct      struct with optimization options, set to [] if default settings
    
    % Outputs:
    % thetahat      n x 1       EB point estimates
    % ci            n x 2       EBCIs
    % w_estim       n x 1       shrinkage factors (either w_EB or w_opt)
    % normlng       n x 1       half-length of EBCIs, divided by sigma_i
    % mu2           1 x 1       estimated second moment of epsilon_i
    % kappa         1 x 1       estimated kurtosis of epsilon_i
    % delta         k x 1       OLS coefficients in regression of Y_i on X_i (or Y_i/sigma_i on X_i for t-stat shrinkage)
    
    
    % Input parser
    p = inputParser;
    addRequired(p, 'Y', @isnumeric);
    addRequired(p, 'X', @isnumeric);
    addRequired(p, 'sigma', @isnumeric);
    addRequired(p, 'alpha', @isnumeric);
    addParameter(p, 'mu2', [], @isnumeric);
    addParameter(p, 'kappa', [], @isnumeric);
    addParameter(p, 'weights', [], @(x) isnumeric(x) || isempty(x));
    addParameter(p, 'param', false, @islogical);
    addParameter(p, 'tstat', false, @islogical);
    addParameter(p, 'w_opt', false, @islogical);
    addParameter(p, 'use_kappa', true, @islogical);
    addParameter(p, 'fs_correction', 'PMT', @ischar);
    addParameter(p, 'verbose', false, @islogical);
    addParameter(p, 'opt_struct', [], @(x) isstruct(x) || isempty(x));
    parse(p, Y, X, sigma, alpha, varargin{:});
    
    % Define outcome data
    Y_norm = Y;
    if p.Results.tstat % If t-stat shrinkage, divide by sigma
        Y_norm = Y./sigma;
    end
    
    % Weights
    if isempty(p.Results.weights)
        weights = ones(length(Y_norm),1);
    else
        weights = p.Results.weights;
    end
    
    % Determine shrinkage direction
    if ~isempty(X)
        X_weight = sqrt(weights).*X;
        Y_norm_weight = sqrt(weights).*Y_norm;
        delta = X_weight(weights~=0,:)\Y_norm_weight(weights~=0);
        mu1 = X*delta; % Shrink towards regression estimate mu_{1,i}=X_i'*delta
    else
        mu1 = 0; % Shrink towards zero
        delta = [];
    end
    
    % Preliminary moment calculations + parametric EB shrinkage factor and length
    mu2 = p.Results.mu2;
    kappa = p.Results.kappa;
    if p.Results.tstat
        if isempty(mu2)
            [mu2, kappa] = moment_conv(Y_norm-mu1, 1, weights, p.Results.fs_correction); % Estimates of 2nd moment and kurtosis of epsilon_i=(theta_i/sigma_i-mu_{1,i})
        end
        [w_eb, lngth_param] = parametric_ebci(mu2, alpha);
    else
        if isempty(mu2)
            [mu2, kappa] = moment_conv(Y-mu1, sigma, weights, p.Results.fs_correction); % Estimates of 2nd moment and kurtosis of epsilon_i=(theta_i-mu_{1,i})
        end
        [w_eb, lngth_param] = parametric_ebci(mu2./(sigma.^2), alpha);
    end
    
    if mu2>eps && ~p.Results.param % If robust CI is desired...
        
        if isempty(p.Results.opt_struct)
            opt_struct = opt_struct_default(); % Default numerical options
        else
            opt_struct = p.Results.opt_struct;
        end
        
        w = w_eb;
        if p.Results.w_opt
            w = [];
        end
        
        kappa_cv = kappa;
        if ~p.Results.use_kappa
            kappa_cv = []; % Do not use kurtosis to compute critical value
        end
        
        if ~p.Results.tstat % If moment independence assumption is imposed...
            
            % Treat observations separately
            n = length(Y);
            verbose = p.Results.verbose;
            w_estim = nan(n,1);
            normlng = nan(n,1);
            
            if verbose
                disp('Computing robust EBCI for each observation.');
            end
            
            parfor i=1:n % Parallel loop over observations
                
                the_w = [];
                if ~isempty(w)
                    the_w = w(i);
                end
                
                % Shrinkage factor and critical value for observation i
                [w_estim(i), normlng(i)] = robust_ebci(the_w, mu2/(sigma(i)^2), kappa_cv, alpha, opt_struct);
                
                % Print progress
                if verbose && mod(i, ceil(n/100))==0
                    fprintf('%s%3d%s\n', repmat(' ', 1, floor(50*i/n)), round(100*i/n), '%');
                end
                
            end
            
            if verbose
                disp('Done.');
            end
            
        else % If t-stat shrinkage...
            
            % Only need to compute a single shrinkage factor and critical value
            [w_estim, normlng] = robust_ebci(w, mu2, kappa_cv, alpha, opt_struct);
            
        end
        
    elseif mu2>eps % If parametric CI...
        
        w_estim = w_eb;
        normlng = lngth_param;
        
    else % Degenerate case with mu2=0
        
        w_estim = w_eb;
        normlng = 0;
        
    end
    
    thetahat = mu1 + w_estim.*(Y_norm-mu1); % Point estimate: shrink toward mu_{1,i}
    if p.Results.tstat
        thetahat = thetahat.*sigma; % If t-stat shrinkage, scale up by sigma again
        w_estim = repmat(w_estim, size(thetahat));
        normlng = repmat(normlng, size(thetahat));
    end
    ci = thetahat + (normlng.*sigma)*[-1 1]; % Confidence interval

end
