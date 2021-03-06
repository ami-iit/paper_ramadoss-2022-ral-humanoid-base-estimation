classdef Filter < handle
    properties (Access = private)
        timestamp_id (1, 1) uint64;
        
        X (:, :) double;
        P (:, :) double;
        
        t_prev (1, 1) double;
        X_prev (:, :) double;
        P_prev (:, :) double;
        alpha_prev (3, 1) double;
        omega_prev (3, 1) double;
        encoders_prev (:, 1) double;
        contacts_prev (2, 1) logical;
        
        X0 (:, :) double;
        P0 (:, :) double;
        
        Qg (3, 3) double; % gyro variance
        Qa (3, 3) double; % accelerometer variance
        Qcontact (6, 6) double; % contact foot pose variance
        Qswing (6, 6) double; % swing foot pose variance
        Qba (3, 3) double; % gyro bias variance
        Qbg (3, 3) double; % accelerometer bias variance
        
        Renc (:, :) double; % encoder variance
        R0fkin (6, 6) double; % forward kinematic pose variance
        
        model_comp ;
        options Estimation.Proprioception.EstimatorOptions;
        
        debugger Estimation.Proprioception.DebugOutputs;
        
        filter_configured (1, 1) logical;
        filter_initialized (1, 1) logical;
        bias_initialized (1, 1) logical;

        Rimu3, Rimuinv
    end
    
    properties (Access = private, Constant)
        g = [0; 0; -9.80665];
    end
    
    methods
        function obj = Filter()
            obj.timestamp_id = 0;
            obj.Qa = zeros(3);
            obj.Qg = zeros(3);
            obj.Qcontact = zeros(6);
            obj.Qswing = zeros(6);
            obj.Qba = zeros(3);
            obj.Qbg = zeros(3);
            obj.R0fkin = zeros(6);
            obj.t_prev = 0.0;
            obj.alpha_prev = zeros(3, 1);
            obj.omega_prev = zeros(3, 1);
            obj.contacts_prev = false(2, 1);            
            
            obj.options = Estimation.Proprioception.EstimatorOptions();
            obj.debugger = Estimation.Proprioception.DebugOutputs();
            
            obj.filter_configured = false;
            obj.filter_initialized = false;
            obj.bias_initialized = false;
        end
        
        function obj = setup(obj, prior_dev, sensors_dev, model_comp, options)
            arguments
                obj Estimation.CODILIGENT_KIO.Filter;
                prior_dev Estimation.Proprioception.PriorsStdDev;
                sensors_dev Estimation.Proprioception.SensorsStdDev;
                model_comp ;
                options Estimation.Proprioception.EstimatorOptions;
            end
            obj.model_comp = model_comp;
            obj.options = options;
            
            obj.Qa = diag(sensors_dev.accel_noise.^2);
            obj.Qg = diag(sensors_dev.gyro_noise.^2);
            obj.Qcontact(1:3, 1:3) = diag(sensors_dev.contact_foot_linvel_noise.^2);
            obj.Qswing(1:3, 1:3) = diag(sensors_dev.swing_foot_linvel_noise.^2);
            obj.Qcontact(4:6, 4:6) = diag(sensors_dev.contact_foot_angvel_noise.^2);
            obj.Qswing(4:6, 4:6) = diag(sensors_dev.swing_foot_angvel_noise.^2);
            obj.Qba = diag(sensors_dev.accel_bias_noise.^2);
            obj.Qbg = diag(sensors_dev.gyro_bias_noise.^2);
            
            assert(options.nr_joints_est == length(sensors_dev.encoders_noise), 'Mismatch #joints in options');
            obj.encoders_prev = zeros(options.nr_joints_est, 1);
            obj.Renc = diag(sensors_dev.encoders_noise.^2);
            
            obj.R0fkin = diag(prior_dev.forward_kinematics.^2);
            
            obj.P0 = blkdiag(diag(prior_dev.imu_position.^2), ...
                             diag(prior_dev.imu_orientation.^2), ...                
                             diag(prior_dev.imu_linear_velocity.^2), ...
                             diag(prior_dev.left_foot_position.^2), ...
                             diag(prior_dev.left_foot_orientation.^2), ... 
                             diag(prior_dev.right_foot_position.^2), ...
                             diag(prior_dev.right_foot_orientation.^2));            
            if (options.enable_bias_estimation)
               obj.P0 = blkdiag(obj.P0, ...
                                diag(prior_dev.accel_bias.^2), ...
                                diag(prior_dev.gyro_bias.^2));                
            end
            
            obj.P_prev = obj.P0;
            
            obj.filter_configured = true;
            obj.filter_initialized = false;
            obj.bias_initialized = false;

            Rimu = obj.model_comp.kindyn.model().getFrameTransform(obj.model_comp.base_link_imu_idx).getRotation().toMatlab();
            obj.Rimu3 = blkdiag(Rimu, Rimu, Rimu);
            obj.Rimuinv = blkdiag(Rimu',Rimu', Rimu');
        end % setup
        
        function obj = initialize(obj, X0)
            if (obj.filter_configured)
                if (obj.options.enable_bias_estimation)
                    assert(length(X0) == 20, 'State size mismatch');
                else
                    assert(size(X0, 2) == 13, 'State size mismatch');
                end
                
                obj.X0 = X0;
                obj.X = X0;
                obj.X_prev = X0;
                
                obj.P = obj.P0;
                
                obj.filter_initialized = true;
            end
        end
        
        function [X, P, BaseLinkState, DebugOut, obj] = advance(obj, t, omega, alpha, encoders, contacts)
            % TODO intialize bias static pose
            % obj.initializeBias(alpha, omega, obj.x0)
            obj.timestamp_id = obj.timestamp_id + 1;
            obj.X_prev = obj.X;
            obj.P_prev = obj.P;

            if (obj.filter_initialized && obj.t_prev > 0.0)
                dt = t - obj.t_prev;
                obj = obj.predictState(obj.omega_prev, obj.alpha_prev, obj.contacts_prev, dt);
                
                if obj.options.enable_ekf_update
                    if obj.options.enable_kinematic_meas
                        obj = obj.updateKinematics(encoders, contacts, dt);
                    end
                    
                    if obj.options.debug_mode
                        obj.debugger.access = true;
                    end
                end
            end
            
            % store latest values
            obj.omega_prev = omega;
            obj.alpha_prev = alpha;
            obj.encoders_prev = encoders;
            obj.contacts_prev = contacts;
            obj.t_prev = t;
            
            % outputs
            X = obj.X;
            P = obj.P;
            
            % extract base link state
            [R, p, v, ~, ~, ~, ~, ~, bg] = Estimation.CODILIGENT_KIO.State.extract(obj.X);
            q = Utils.rot2quat(R);
            [BaseLinkState.q, BaseLinkState.I_p, BaseLinkState.I_pdot, BaseLinkState.I_omega] = obj.model_comp.getBaseStateFromIMUState(q, p, v, omega-bg);
            
            DebugOut = obj.debugger;
        end
    end
    
    methods (Access = private)
        function obj = predictState(obj, omega, alpha, contact, dt)
            [R, p, v, Zl, pl, Zr, pr, ba, bg] = Estimation.CODILIGENT_KIO.State.extract(obj.X);
            
            %- bias corrected IMU measurements
            alpha_unbiased = alpha - ba;
            omega_unbiased = omega - bg;
            acc = (R*alpha_unbiased + obj.g);
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %%-- non linear dynamics
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % base pose
            R_pred = LieGroups.SO3.compose(R, LieGroups.SO3.exphat(omega_unbiased*dt));
            v_pred = v + acc*dt;
            p_pred = p + v*dt + 0.5*acc*dt*dt;
            
            % feet position
%             [IMU_q_LF, IMU_p_LF, ~] = obj.model_comp.relativeKinIMU_to_foot_contact(encoders, 'left');
%             [IMU_q_RF, IMU_p_RF, ~] = obj.model_comp.relativeKinIMU_to_foot_contact(encoders, 'right');
%             IMU_R_LF = Utils.quat2rot(IMU_q_LF);
%             IMU_R_RF = Utils.quat2rot(IMU_q_RF);
            
%             pr_off = p_pred + R_pred*IMU_p_RF;
%             pl_off =  p_pred + R_pred*IMU_p_LF;
%             pr_pred = contact(2)*pr + (1 - contact(2))*pr_off;
%             pl_pred = contact(1)*pl + (1 - contact(1))*pl_off;
            
            pr_pred = pr;
            pl_pred = pl;

            Zr_pred = Zr;
            Zl_pred = Zl;
            
            % bias
            ba_pred = ba;
            bg_pred = bg;
            
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %%--Linearized invariant error dynamics
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            wCross = -Utils.skew(omega_unbiased);
            aCross = -Utils.skew(alpha_unbiased);
            Fc = [wCross     zeros(3)      eye(3)  zeros(3,12); ...
                 zeros(3)    zeros(3)    zeros(3)  zeros(3,12); ...
                 zeros(3)      aCross      wCross  zeros(3,12); ...
              zeros(12,3) zeros(12,3) zeros(12,3) zeros(12,12)];

            if obj.options.enable_bias_estimation
                Fc = blkdiag(Fc, zeros(6));
                
                Fc(1:9, end-5:end) = [   zeros(3) zeros(3); ...
                                         zeros(3)  -eye(3); ...
                                          -eye(3) zeros(3)];
            end
            
            Fk = eye(size(Fc)) + (Fc*dt);
            
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %%-- Discrete system noise covariance
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            dimWoBias = 21;
            Lc = eye(dimWoBias);
            Qc = blkdiag(zeros(3), obj.Qg, obj.Qa,...
                         contact(1)*obj.Qcontact + (1-contact(1))*obj.Qswing, ...
                         contact(2)*obj.Qcontact + (1-contact(2))*obj.Qswing);
            if obj.options.enable_bias_estimation
                Lc = blkdiag(Lc, eye(6));
                Qc = blkdiag(Qc, obj.Qba, obj.Qbg);
            end
            
            Qk = Fk*Lc*Qc*Lc'*Fk'*dt;

            obj.X = Estimation.CODILIGENT_KIO.State.construct(R_pred, p_pred, v_pred, ...
                                                         Zl_pred, pl_pred,  ...
                                                         Zr_pred, pr_pred, ...
                                                         ba_pred, bg_pred, ...
                                                         obj.options.enable_bias_estimation);
            obj.P = Fk*obj.P*Fk'+ Qk;
            
            if obj.options.debug_mode
                obj.debugger.predicted_acc = acc;
                obj.debugger.F = Fk;
                obj.debugger.P_pred = obj.P;
                obj.debugger.Q = Qk;
            end
        end % predictState
        
        function obj = updateState(obj, deltaY, H, R)
            S = H*obj.P*H' + R;
            K = (obj.P*H')/S;
            deltaX = K*deltaY;
            
            deltaX_lifted = Estimation.CODILIGENT_KIO.State.exphat(deltaX);

            obj.X = Estimation.CODILIGENT_KIO.State.compose(obj.X, deltaX_lifted);
            
            I = eye(size(obj.P));
            rightJacobiandeltaX = Estimation.CODILIGENT_KIO.State.rightJacobian(deltaX);
            obj.P = rightJacobiandeltaX*(I - (K*H))*obj.P*rightJacobiandeltaX';
            obj.P = (obj.P + obj.P')./2;
            
            if obj.options.debug_mode
                eigval = eig(obj.P);
                condn = max(eigval)/min(eigval);
                
                tol = length(eigval)*eps(max(eigval));
                isposdef = all(eigval > tol);
                
                obj.debugger.traceP = trace(obj.P);
                obj.debugger.condP = condn;
                obj.debugger.isPsymmetric = issymmetric(obj.P);
                obj.debugger.isPpositivedefinite = isposdef;
                obj.debugger.isPSPD = (issymmetric(obj.P) && isposdef);
                
                obj.debugger.H = H;
                obj.debugger.R = R;
                obj.debugger.K = K;
                obj.debugger.deltay = deltaY;
                obj.debugger.deltax = deltaX;

                obj.debugger.PextPoseBase = obj.Rimu3*obj.P(1:9, 1:9)*obj.Rimuinv;
            end
            
        end % updateState
        
        function obj = updateKinematics(obj, encoders, contacts, dt)
            [A_R_IMU, p, ~, A_R_LF, pl, A_R_RF, pr, ~, ~] = Estimation.CODILIGENT_KIO.State.extract(obj.X);
            A_H_IMU = LieGroups.SE3.constructSE3(A_R_IMU, p);
            IMU_H_A =   LieGroups.SE3.inverse(A_H_IMU);
            A_H_LF = LieGroups.SE3.constructSE3(A_R_LF, pl);
            A_H_RF = LieGroups.SE3.constructSE3(A_R_RF, pr);
            IMU_H_LF = LieGroups.SE3.compose(IMU_H_A, A_H_LF);
            IMU_H_RF = LieGroups.SE3.compose(IMU_H_A, A_H_RF);
            
            % Jacobian we get here allows us to express the feet velocities
            % in the feet frames, no need for additional transformations
            [y_LF, LF_J_IMULF] = obj.model_comp.relativeKinIMU_to_foot_contactExplicit(encoders, 'left');
            [y_RF, RF_J_IMURF] = obj.model_comp.relativeKinIMU_to_foot_contactExplicit(encoders, 'right');
            
            if (contacts(1) && contacts(2))
                %%%%%%%%%%%%%%%%%%%%%%%%
                %%-- double support
                %%%%%%%%%%%%%%%%%%%%%%%%
                % measurement model                
                h_of_x = LieGroups.SE3xSE3.constructSE3bySE3(IMU_H_LF, IMU_H_RF);
                
                % observation
                y = LieGroups.SE3xSE3.constructSE3bySE3(y_LF, y_RF);
                
                % innovation
                hinv = LieGroups.SE3xSE3.inverse(h_of_x);
                double_composite_pose_error =  LieGroups.SE3xSE3.compose(hinv, y);
                deltaY = LieGroups.SE3xSE3.logvee(double_composite_pose_error);

                Rk = blkdiag(LF_J_IMULF*obj.Renc*LF_J_IMULF', ...
                             RF_J_IMURF*obj.Renc*RF_J_IMURF');
                Rk = Rk/dt;
                
                % measurement model Jacobian
                H_lf = [-A_R_LF'*A_R_IMU    -(A_R_LF')*Utils.skew(p - pl)*(A_R_IMU)   zeros(3)   eye(3)  zeros(3) zeros(3) zeros(3); ...
                                zeros(3)                          -A_R_LF'*A_R_IMU   zeros(3) zeros(3)    eye(3) zeros(3) zeros(3)];

                H_rf = [-A_R_RF'*A_R_IMU    -(A_R_RF')*Utils.skew(p - pr)*(A_R_IMU)   zeros(3)   zeros(3)  zeros(3) eye(3) zeros(3); ...
                                zeros(3)                          -A_R_RF'*A_R_IMU   zeros(3) zeros(3)    zeros(3) zeros(3) eye(3)];
                

                if obj.options.enable_bias_estimation
                    H_lf = [H_lf zeros(6)];
                    H_rf = [H_rf zeros(6)];
                end
                
                H = [H_lf; H_rf];
                obj = obj.updateState(deltaY, H, Rk);
            elseif (contacts(1))
                %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                %%-- single support left foot
                %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                % measurement model                
                h_of_x = IMU_H_LF;
                
                % observation
                y = y_LF;
                
                % innovation
                hinv = LieGroups.SE3.inverse(h_of_x);
                pose_error =  LieGroups.SE3.compose(hinv, y);
                deltaY = LieGroups.SE3.logvee(pose_error);
                
                Rk = blkdiag(LF_J_IMULF*obj.Renc*LF_J_IMULF');
                Rk = Rk/dt;
                                
                % measurement model Jacobian               
                H_lf = [-A_R_LF'*A_R_IMU    -(A_R_LF')*Utils.skew(p - pl)*(A_R_IMU)   zeros(3)   eye(3)  zeros(3) zeros(3) zeros(3); ...
                                zeros(3)                          -A_R_LF'*A_R_IMU      zeros(3) zeros(3)    eye(3) zeros(3) zeros(3)];
                

                if obj.options.enable_bias_estimation
                    H_lf = [H_lf zeros(6)];
                end
                
                H = H_lf;
                obj = obj.updateState(deltaY, H, Rk);
            elseif (contacts(2))
                %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                %%-- single support right foot
                %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                % measurement model
                h_of_x = IMU_H_RF;
                
                % observation
                y = y_RF;
                
                % innovation
                hinv = LieGroups.SE3.inverse(h_of_x);
                pose_error =  LieGroups.SE3.compose(hinv, y);
                deltaY = LieGroups.SE3.logvee(pose_error);
                
                Rk = blkdiag(RF_J_IMURF*obj.Renc*RF_J_IMURF');
                Rk = Rk/dt;
                
                % measurement model Jacobian                                
                H_rf = [-A_R_RF'*A_R_IMU    -(A_R_RF')*Utils.skew(p - pr)*(A_R_IMU)   zeros(3)   zeros(3)  zeros(3) eye(3) zeros(3); ...
                                zeros(3)                          -A_R_RF'*A_R_IMU   zeros(3) zeros(3)    zeros(3) zeros(3) eye(3)];

                if obj.options.enable_bias_estimation
                    H_rf = [H_rf zeros(6)];
                end
                
                H = H_rf;
                obj = obj.updateState(deltaY, H, Rk);
            end
            
            if obj.options.debug_mode
                if sum(contacts) > 0
                    obj.debugger.y = y;
                    obj.debugger.z = h_of_x;                    
                end
            end
            
        end % updateKinematics                        
    end
    
end


