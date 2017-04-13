function [resultGUI,info] = matRad_directApertureOptimization(dij,cst,apertureInfo,resultGUI,pln,scaleDij,scaleDRx)
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% matRad function to run direct aperture optimization
%
% call
%   o[optResult,info] = matRad_directApertureOptimization(dij,cst,apertureInfo,optResult,pln,visBool)
%
% input
%   dij:            matRad dij struct
%   cst:            matRad cst struct
%   apertureInfo:   aperture shape info struct
%   optResult:      resultGUI struct to which the output data will be added, if
%                   this field is empty optResult struct will be created
%                   (optional)
%   pln:            matRad pln struct
%   visBool:        plots the objective function value in dependence of the
%                   number of iterations
%
% output
%   optResult:  struct containing optimized fluence vector, dose, and
%               shape info
%   info:       struct containing information about optimization
%
% References
%   [1] http://dx.doi.org/10.1118/1.4914863
%
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% Copyright 2015 the matRad development team. 
% 
% This file is part of the matRad project. It is subject to the license 
% terms in the LICENSE file found in the top-level directory of this 
% distribution and at https://github.com/e0404/matRad/LICENSES.txt. No part 
% of the matRad project, including this file, may be copied, modified, 
% propagated, or distributed except according to the terms contained in the 
% LICENSE file.
%
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

if nargin < 6
    scaleDij = 0;
    scaleDRx = 0;
elseif nargin <7
    scaleDRx = 0;
end

if ~isdeployed % only if _not_ running as standalone
    
    % add path for optimization functions    
    matRadRootDir = fileparts(mfilename('fullpath'));
    addpath(fullfile(matRadRootDir,'optimization'))
    
    % get handle to Matlab command window
    mde         = com.mathworks.mde.desk.MLDesktop.getInstance;
    cw          = mde.getClient('Command Window');
    xCmdWndView = cw.getComponent(0).getViewport.getComponent(0);
    h_cw        = handle(xCmdWndView,'CallbackProperties');

    % set Key Pressed Callback of Matlab command window
    set(h_cw, 'KeyPressedCallback', @matRad_CWKeyPressedCallback);

end

% initialize global variables for optimizer
global matRad_global_x;
global matRad_global_d;
global matRad_STRG_C_Pressed;
global matRad_objective_function_value;

matRad_global_x                 = NaN * ones(dij.totalNumOfBixels,1); % works with bixel weights even though we do dao!
matRad_global_d                 = NaN * ones(dij.numOfVoxels,1);
matRad_STRG_C_Pressed           = false;
matRad_objective_function_value = [];

% adjust overlap priorities
cst_Over = matRad_setOverlapPriorities(cst);

% adjust objectives _and_ constraints internally for fractionation 
for i = 1:size(cst_Over,1)
    for j = 1:size(cst_Over{i,6},1)
       cst_Over{i,6}(j).dose = cst_Over{i,6}(j).dose/pln.numOfFractions;
    end
end

if isfield(apertureInfo,'scaleFacRx')
    %weights were scaled to acheive 95% PTV coverage
    %scale back to "optimal" weights
    apertureInfo.apertureVector(1:apertureInfo.totalNumOfShapes) = apertureInfo.apertureVector(1:apertureInfo.totalNumOfShapes)/apertureInfo.scaleFacRx;
end

if scaleDij
    %rescale dij matrix, so that apertureWeight/bixelWidth ~= 1
    dij.scaleFactor = mean(apertureInfo.apertureVector(1:apertureInfo.totalNumOfShapes))/apertureInfo.bixelWidth;
    
    dij.physicalDose{1} = dij.physicalDose{1}*dij.scaleFactor;
    dij.weightToMU = dij.weightToMU*dij.scaleFactor;
    
    apertureInfo.weightToMU = apertureInfo.weightToMU*dij.scaleFactor;
    apertureInfo.apertureVector(1:apertureInfo.totalNumOfShapes) = apertureInfo.apertureVector(1:apertureInfo.totalNumOfShapes)/dij.scaleFactor;
end

% update aperture info vector
apertureInfo = matRad_daoVec2ApertureInfo(apertureInfo,apertureInfo.apertureVector);

% Set the IPOPT options.
matRad_ipoptOptions;

% set bounds on optimization variables
options.lb              = apertureInfo.limMx(:,1);                                          % Lower bound on the variables.
options.ub              = apertureInfo.limMx(:,2);                                          % Upper bound on the variables.
if isfield(pln,'VMAT') && pln.VMAT
    [options.cl,options.cu] = matRad_daoGetConstBounds(cst_Over,apertureInfo,options,pln.leafSpeedCst,pln.doseRateCst);   % Lower and upper bounds on the constraint functions.
    options.VMAT = pln.VMAT;
else
    [options.cl,options.cu] = matRad_daoGetConstBounds(cst_Over,apertureInfo,options);   % Lower and upper bounds on the constraint functions.
    options.VMAT = 0;
end

% set optimization options
options.radMod          = pln.radiationMode;
options.bioOpt          = pln.bioOptimization;
options.ID              = [pln.radiationMode '_' pln.bioOptimization];
options.numOfScenarios  = dij.numOfScenarios;

% set callback functions.
funcs.objective         = @(x) matRad_daoObjFunc(x,apertureInfo,dij,cst_Over,options);
funcs.gradient          = @(x) matRad_daoGradFunc(x,apertureInfo,dij,cst_Over,options);
funcs.iterfunc          = @(iter,objective,parameter) matRad_IpoptIterFunc(iter,objective,parameter,options.ipopt.max_iter);
funcs.constraints       = @(x) matRad_daoConstFunc(x,apertureInfo,dij,cst_Over,options);
funcs.jacobian          = @(x) matRad_daoJacobFunc(x,apertureInfo,dij,cst_Over,options);
funcs.jacobianstructure = @( ) matRad_daoGetJacobStruct(apertureInfo,dij,cst_Over);

% Run IPOPT.
[optApertureInfoVec, info] = ipopt(apertureInfo.apertureVector,funcs,options);

% unset Key Pressed Callback of Matlab command window and delete waitbar
if ~isdeployed
    set(h_cw, 'KeyPressedCallback',' ');
end

% clear global variables after optimization
clearvars -global matRad_global_x matRad_global_d;

if scaleDij
    %rescale dij matrix
    dij.physicalDose{1} = dij.physicalDose{1}/dij.scaleFactor;
    dij.weightToMU = dij.weightToMU/dij.scaleFactor;
    
    apertureInfo.weightToMU = apertureInfo.weightToMU/dij.scaleFactor;
    optApertureInfoVec(1:apertureInfo.totalNumOfShapes) = optApertureInfoVec(1:apertureInfo.totalNumOfShapes)*dij.scaleFactor;
end

% update the apertureInfoStruct and calculate bixel weights
resultGUI.apertureInfo = matRad_daoVec2ApertureInfo(apertureInfo,optApertureInfoVec);

% update apertureInfoStruct with the maximum leaf speeds per segment
if isfield(pln,'VMAT') && pln.VMAT
    resultGUI.apertureInfo = matRad_maxLeafSpeed(resultGUI.apertureInfo);
    
    
    %optimize delivery
    resultGUI = matRad_optDelivery(resultGUI,pln,1);
    resultGUI = matRad_calcDeliveryMetrics(resultGUI,pln);
end

% override also bixel weight vector in optResult struct
resultGUI.w    = resultGUI.apertureInfo.bixelWeights;
resultGUI.wDao = resultGUI.apertureInfo.bixelWeights;

% calc dose and reshape from 1D vector to 3D array
resultGUI.physicalDose = reshape(dij.physicalDose{1}*resultGUI.w,dij.dimensions);


if scaleDRx
    %Scale D95 in target to RXDose
    resultGUI = matRad_calcQualityIndicators(resultGUI,cst,pln);
    
    resultGUI.apertureInfo.scaleFacRx = max((pln.DRx/pln.numOfFractions)./[resultGUI.QI(pln.RxStruct).D95]');
    optApertureInfoVec(1:resultGUI.apertureInfo.totalNumOfShapes) = optApertureInfoVec(1:resultGUI.apertureInfo.totalNumOfShapes)*resultGUI.apertureInfo.scaleFacRx;
    
    % update the apertureInfoStruct and calculate bixel weights
    resultGUI.apertureInfo = matRad_daoVec2ApertureInfo(resultGUI.apertureInfo,optApertureInfoVec);
    
    % override also bixel weight vector in optResult struct
    resultGUI.w    = resultGUI.apertureInfo.bixelWeights;
    resultGUI.wDao = resultGUI.apertureInfo.bixelWeights;
    
    % calc dose and reshape from 1D vector to 3D array
    resultGUI.physicalDose = reshape(dij.physicalDose{1}*resultGUI.w,dij.dimensions);
end

