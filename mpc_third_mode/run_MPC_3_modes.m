% Discrete time model of a quadcopter
clear

% load in A and B discrete 
load A_and_B_3modes.mat
[nx, nu] = size(Bd);
n_modes = (nx - 6)/2;

% state and control constraints
umin = -.01*ones(nu,1);
umax = -umin;
xmin = -Inf(nx,1);
xmax = -xmin;

% cost function parameters 
w.mrp = 20;
w.w = 1;
w.n = 1;
w.nd = 1;

% cost function
Q = diag([w.mrp*ones(3,1);w.w*ones(3,1);w.n*ones(n_modes,1);w.nd*ones(n_modes,1)]);
QN = Q;
R = 10.0*eye(nu);

% Initial and reference states
x0 = zeros(nx,1);
xr = zeros(nx,1);

% Prediction horizon
N = 30;

% Cast MPC problem to a QP: x = (x(0),x(1),...,x(N),u(0),...,u(N-1))
% - quadratic objective
P = blkdiag( kron(speye(N), Q), QN, kron(speye(N), R) );
% - linear objective
q = [repmat(-Q*xr, N, 1); -QN*xr; zeros(N*nu, 1)];
% - linear dynamics
Ax = kron(speye(N+1), -speye(nx)) + kron(sparse(diag(ones(N, 1), -1)), Ad);
Bu = kron([sparse(1, N); speye(N)], Bd);
Aeq = [Ax, Bu];

% add the affine stuff here
sc.tau= 10*[.01;.01;.01];
sc.a = [.1;.1;.1];

% throw a disturbance in there at 7.5 seconds 
affine_matrix = zeros(nx,N);
affine_instance = affine_fx(sc.tau,sc.a,sc);
affine_matrix(:,15) = B_affine*affine_instance;

% add affine contribution to dynamics 
leq = [-x0; -vec(affine_matrix)];
ueq = leq;

% - input and state constraints
Aineq = speye((N+1)*nx + N*nu);
lineq = [repmat(xmin, N+1, 1); repmat(umin, N, 1)];
uineq = [repmat(xmax, N+1, 1); repmat(umax, N, 1)];

% - OSQP style constraints
A = [Aeq; Aineq];
l = [leq; lineq];
u = [ueq; uineq];

% Create an OSQP object
prob = osqp;

% Setup workspace
prob.setup(P, q, A, l, u,...
           'eps_abs',1e-3,...
           'eps_rel',1e-3,...
           'eps_prim_inf',1e-3,...
           'eps_dual_inf', 1e-3,...
           'check_termination',10);

% solve 
res = prob.solve();

%% plotting 

% Simulate in closed loop with true nonlinear dynamics
N_sim = 200;
dt = .5;
t_vec = 0:dt:N_sim*dt;
ut_vec = t_vec(1:end-1);
X_mpc_sim = zeros(nx+3,N_sim);
X_mpc_sim(:,1) = [x0;0;0;0];
U_mpc_sim = zeros(nu,N_sim-1);
X_lqr_sim = zeros(nx+3,N_sim);
U_lqr_sim = zeros(nu,N_sim-1);

solve_time_vec = zeros(N_sim+1,1);
solve_time_vec(1) = res.info.solve_time;
for i = 1 : N_sim
    %% MPC simulation
    % Solve the QP
    res = prob.solve();
    solve_time_vec(i+1) = res.info.solve_time;
    % Check solver status
    if ~strcmp(res.info.status, 'solved')
        error('OSQP did not solve the problem!')
    end

    % Apply first control input to the plant
    U_mpc_sim(:,i) = clamp(res.x((N+1)*nx+1:(N+1)*nx+nu),umin(1),umax(1));

    % step forward dt
    X_mpc_sim(:,i+1) = rk4(@ODE,t_vec(i),X_mpc_sim(:,i),U_mpc_sim(:,i),sc,dt);

    % Update initial state
    [l,u] = shift_affine(X_mpc_sim(1:nx,i+1),l,u,N, nx);
    prob.update('l', l, 'u', u);
    
    %% LQR simulation
    
    % control input 
    U_lqr_sim(:,i) = clamp(-K_lqr*X_lqr_sim(1:12,i),umin(1),umax(1));
    
    % step forward dt
    X_lqr_sim(:,i+1) = rk4(@ODE,t_vec(i),X_lqr_sim(:,i),U_lqr_sim(:,i),sc,dt);
    
    
end

%% plot timing 


figure
hold on 
% title('MPC Solve Times')
plot(t_vec,solve_time_vec'*1000,'k.','markersize',15)
plot(t_vec,ones(length(t_vec),1),'k--')
xlabel('Time (s)')
ylim([0 2])
ylabel('Solve Time (ms)')
hold off 



%% Angle error and slew rates 

angle_error_mpc_sim = zeros(1,N_sim);
angle_error_lqr = zeros(1,N_sim);

slew_rate_mpc = zeros(1,N_sim);
slew_rate_lqr = zeros(1,N_sim);

for i = 1:N_sim
     angle_error_lqr(i) = norm(phi_from_p(X_lqr_sim(1:3,i)));
    angle_error_mpc_sim(i) = norm(phi_from_p(X_mpc_sim(1:3,i)));
    
    slew_rate_lqr(i) = norm(X_lqr_sim(4:6,i));
    slew_rate_mpc(i) = norm(X_mpc_sim(4:6,i));
end

%% plot slew rates 
figure
hold on 
plot(ut_vec,rad2deg(slew_rate_lqr),'k--')
plot(ut_vec,rad2deg(slew_rate_mpc),'k','linewidth',1.5)
legend('LQR','MPC')
ylabel('Slew Rate (deg/s)')
xlabel('Time (s)')
hold off 

%% Plot both approaches 

angle_error_mpc = angle_error_mpc_sim;
X = X_mpc_sim;
U = U_mpc_sim;
figure
hold on 
sgtitle('MPC vs LQR Station-Keeping')

subplot(3,2,1)
plot(ut_vec,rad2deg(angle_error_mpc))
title('MPC Pointing Error')
ylabel('Pointing Error (deg)')
xlabel('Time (s)')
ylim([0 15])
hold off 

subplot(3,2,2)
plot(ut_vec,rad2deg(angle_error_lqr))
title('LQR Pointing Error')
ylabel('Pointing Error (deg)')
xlabel('Time (s)')
ylim([0 15])
hold off 

% modal coordinate 
subplot(3,2,3)
plot(t_vec,X_mpc_sim(7:9,:)')
legend('Mode 1','Mode 2','Mode 3')
title('MPC Modal Coordinate')
ylabel('Modal Coordinate')
xlabel('Time (s)')
ylim([-.2 .2])
hold off 

subplot(3,2,4)
plot(t_vec,X_lqr_sim(7:9,:)')
legend('Mode 1','Mode 2','Mode 3')
title('LQR Modal Coordinate')
ylabel('Modal Coordinate')
xlabel('Time (s)')
ylim([-.2 .2])
hold off 

% Control 
subplot(3,2,5)
stairs(ut_vec,U_mpc_sim')
title('MPC U')
ylabel('N*m')
xlabel('Time (s)')
legend('u_1','u_2','u_3')
ylim([-.011 .011])
hold off 

subplot(3,2,6)
stairs(ut_vec,U_lqr_sim(1:3,:)')
title('LQR U')
ylabel('N*m')
xlabel('Time (s)')
legend('u_1','u_2','u_3')
ylim([-.011 .011])
hold off 

%% 
col_lqr = [.9 .9 .9];
col_mpc = [.2 .2 .2];

figure
hold on 
subplot(3,1,1)
hold on 
stairs(ut_vec,U_lqr_sim(1,:)','k--')
stairs(ut_vec,U_mpc_sim(1,:)','k','linewidth',1.5)
ylabel('u_1')
legend('LQR','MPC')
% title('LQR U_1')
% ylabel('N*m')

hold on 
subplot(3,1,2)
hold on 
stairs(ut_vec,U_lqr_sim(2,:)','k--')
stairs(ut_vec,U_mpc_sim(2,:)','k','linewidth',1.5)
ylabel('u_2')
legend('LQR','MPC')
% title('LQR U_1')
% ylabel('N*m')

hold on 
subplot(3,1,3)
hold on 
stairs(ut_vec,U_lqr_sim(3,:)','k--')
stairs(ut_vec,U_mpc_sim(3,:)','k','linewidth',1.5)
legend('LQR','MPC')
ylabel('u_3')
xlabel('Time (s)')
% title('LQR U_1')
% ylabel('N*m')

%% three seperate plots 
figure
hold on 

stairs(ut_vec,U_lqr_sim(1,:)','k--')
stairs(ut_vec,U_mpc_sim(1,:)','k','linewidth',1.5)
ylabel('u_1')
legend('LQR','MPC','Location','northeastoutside')
% title('LQR U_1')
% ylabel('N*m')
% matlab2tikz('3mode_u1.tex')

figure
hold on 
stairs(ut_vec,U_lqr_sim(2,:)','k--')
stairs(ut_vec,U_mpc_sim(2,:)','k','linewidth',1.5)
ylabel('u_2')
legend('LQR','MPC','Location','northeastoutside')
% title('LQR U_1')
% ylabel('N*m')
% matlab2tikz('3mode_u2.tex')


figure
hold on 
stairs(ut_vec,U_lqr_sim(3,:)','k--')
stairs(ut_vec,U_mpc_sim(3,:)','k','linewidth',1.5)
legend('LQR','MPC','Location','northeastoutside')
ylabel('u_3')
xlabel('Time (s)')
% title('LQR U_1')
% matlab2tikz('3mode_u3.tex')


%% angle error 

figure
hold on 
plot(ut_vec,rad2deg(angle_error_lqr),'k--')
plot(ut_vec,rad2deg(angle_error_mpc),'k','linewidth',1.5)
legend('LQR','MPC')
ylabel('Pointing Error (deg)')
xlabel('Time (s)')
hold off 

%% 

maxeta1 = max(max(abs(X_lqr_sim(7,:))),max(abs(X_mpc_sim(7,:))));
maxeta2 = max(max(abs(X_lqr_sim(8,:))),max(abs(X_mpc_sim(8,:))));
maxeta3 = max(max(abs(X_lqr_sim(9,:))),max(abs(X_mpc_sim(9,:))));




figure
hold on 
plot(t_vec,X_lqr_sim(7,:)'/maxeta1,'k--')
plot(t_vec,X_mpc_sim(7,:)'/maxeta1,'k','linewidth',1.5)
ylim([-1 1])
ylabel('\eta_1')
legend('LQR','MPC','Location','northeastoutside')
hold off 

% matlab2tikz('3mode_eta1.tex')


figure
hold on 
plot(t_vec,X_lqr_sim(8,:)'/maxeta2,'k--')
plot(t_vec,X_mpc_sim(8,:)'/maxeta2,'k','linewidth',1.5)
ylim([-1 1])
ylabel('\eta_2')
legend('LQR','MPC','Location','northeastoutside')
hold off 

% matlab2tikz('3mode_eta2.tex')


figure
hold on 
plot(t_vec,X_lqr_sim(9,:)'/maxeta3,'k--')
plot(t_vec,X_mpc_sim(9,:)'/maxeta3,'k','linewidth',1.5)
ylim([-1 1])
ylabel('\eta_3')
xlabel('Time (s)')
legend('LQR','MPC','Location','northeastoutside')
hold off 
% matlab2tikz('3mode_eta3.tex')


%% supporting functions 
function y = clamp(x,bl,bu)
  % return bounded value clipped between bl and bu
  y=min(max(x,bl),bu);
end

function aff = affine_fx(tau,a,sc)
% affine dynamics terms 

delta = sc.delta;
phi = sc.phi;
T = sc.T;

aff = [zeros(3,1);
                 (T*tau + T*delta'*phi*a);
                 zeros(sc.n_modes,1);
                (-delta*T*tau - delta*T*delta'*phi*a - phi*a)];
end


function xdot = ODE(t,x,u,sc)
% equations of motion 

p    = x(1:3);
w    = x(4:6);
n    = x(7:9);
ndot = x(10:12);
r    = x(13:15);


if t>= 7.0 && t <7.5
        tau = sc.tau;
        a   = sc.a;
else
        tau = [0.0;0.0;0.0];
        a   = [0.0;0.0;0.0];
end

wdot = sc.T*(tau - sc.B*u  - ...
        cross(w,sc.J*w + sc.delta'*ndot + sc.B*r) +...
        sc.delta'*(sc.C*ndot + sc.K*n + sc.phi*a));

pdot = pdot_from_w(p,w);

nddot = -sc.delta*wdot -sc.C*ndot - sc.K*n - sc.phi*a;

xdot = [pdot;wdot;ndot;nddot;u];


end




function [y_np1] = rk4(ODE,tn,xn,u,sc,h)
% rk4 for a single step 

xn = xn(:);

k1 = h*ODE(tn,xn,u,sc);
k2 = h*ODE(tn + h/2,xn + k1/2,u,sc);
k3 = h*ODE(tn + h/2,xn + k2/2,u,sc);
k4 = h*ODE(tn + h,xn + k3,u,sc);

y_np1 = xn + (1/6)*(k1 + 2*k2 + 2*k3 + k4);

% MRP handling here 
p = y_np1(1:3);

% norm squared
dp2 = dot(p,p);

% if exceeds unity, swap to shadow MRP
if dp2 > 1.0
    ps = -p/dp2;
    y_np1(1:3) = ps;
end



end

function [l,u] = shift_affine(x0,l,u,N, nx)

leq   = l(1:(N+1)*nx);
lineq = l((N+1)*nx+1:end);
% ueq   = u(1:(N+1)*nx);
uineq = u((N+1)*nx+1:end);

leq_shifted = zeros(size(leq));

for i = 1:length(leq_shifted)-nx
    leq_shifted(i) = leq(i+nx);
end

leq_shifted(1:nx) = -x0;


ueq_shifted = leq_shifted;


l = [leq_shifted; lineq];
u = [ueq_shifted; uineq];


end
