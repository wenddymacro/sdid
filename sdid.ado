*! sdid: Synthetic Difference in Differences
*! Version 0.1.0 January 25, 2022
*! Author: Pailañir Daniel, Clarke Damian
*! dpailanir@fen.uchile.cl, dclarke@fen.uchile.cl

cap program drop sdid
program sdid, eclass
version 13.0
	
#delimit ;
    syntax varlist(min=4 numeric), vce(string) 
    [
    seed(numlist integer >0 max=1)
    reps(integer 50)
    controls(string asis)
    graph(string)
    g1_opt(string)
    g2_opt(string)
    unstandardized
    ]
    ;
#delimit cr  

/*
To do:
 (1) Error check
      [A] Ensure blance of panel,
      [B] Ensure no missings in Y, X or treatment
      [C] Ensure no already treated units at the beginning of the panel
      [D] Ensure no units passing from untreated, to treated, back to untreated
      [E] Ensure that there is no inconsistency with standard error type (eg > 1 unit for jackknife)
      [F] Others?
 (2)  Standard errors for staggered adoption (jackknife only)
 (4)  Work out definitve names for R and xsynth control
 (5)  Allow string variables for state, and pass this to graph
 (8)  Replace axis() from egen with our own implementation
 (9)  Work out final display format
 (10) Close off any final graphing issues including saving if desired
 (11) Write help file
*/

*------------------------------------------------------------------------------*
* (0) Error checks in parsing
*------------------------------------------------------------------------------*



*------------------------------------------------------------------------------*
* (1) Basic set-up 
*------------------------------------------------------------------------------*
tokenize `varlist'
tempvar treated ty tyear n
qui gen `ty' = `3' if `4'==1
qui bys `2': egen `treated' = max(`4')
qui by  `2': egen `tyear'   = min(`ty')
sort `3' `treated' `2'
gen `n'=_n
qui sum `3'
local mint=r(min)
qui putmata ori_id=`2' ori_pos=`n' if `3'==`mint' & `tyear'==., replace

local control_opt = 0
if "`controls'"!="" {
    _parse_X `controls'
    if "`r(ctype)'"=="R"      local control_opt = 2
    if "`r(ctype)'"=="xsynth" local control_opt = 1
    local conts = r(controls)

    if `control_opt'==2&length(`"`unstandardized'"')==0 {
        local sconts
        foreach var of varlist `conts' {
            tempvar z`var'
            egen `z`var''= std(`var')
            local sconts `sconts' `z`var''
        }
        local conts `sconts'
    }
}

*------------------------------------------------------------------------------*
* (2) Calculate ATT, plus some locals for inference
*------------------------------------------------------------------------------*
**IDs (`2') go in twice here because we are not resampling
mata: data = st_data(.,("`1' `2' `2' `3' `4' `treated' `tyear' `conts'"))
mata: ATT = synthdid(data, 0, ., ., `control_opt')
mata: OMEGA = ATT.Omega
mata: LAMBDA = ATT.Lambda
mata: st_local("ATT", strofreal(ATT.Tau))


qui count if `3'==`mint'                 //total units
local N=r(N)
qui count if `treated'==0 & `3'==`mint' //control units
local co=r(N)
qui count if `treated'==1 & `3'==`mint' //treated units (total)
local tr=r(N)
local newtr=`co'-`tr'+1                 //start of treated units
qui tab `3'                             //T
local T=r(r)
mkmat `tyear' if `tyear'!=. & `3'==`mint', matrix(tryears) //save adoption values
qui levelsof `tyear', local(tryear) //adoption local

*--------------------------------------------------------------------------*
* (3) Standard error: bootstrap
*--------------------------------------------------------------------------*
if "`vce'"=="bootstrap" {
    cap set seed `seed'
    local b = 1
    local B = `reps'
    mata: ATT_b = J(`B', 1, .)
	
    /*if (`Ntr'==1)==1 {
        di as err "It is not possible to do Bootstrap se because there is only one treated unit"
        exit 198
    }*/
    	
    dis "Bootstrap replications (`reps'). This may take some time."
    dis "----+--- 1 ---+--- 2 ---+--- 3 ---+--- 4 ---+--- 5"

    while `b'<=`B' {
        preserve
        keep `1' `2' `3' `4' `treated' `tyear' `conts'
        tempvar cID
        bsample, cluster(`2') idcluster(`cID')
        qui count if `treated' == 0
        local r1 = r(N)
        qui count if `treated' != 0
        local r2 = r(N)
        
        if (`r1'==0 | `r2'==0) {
            *di "all units are control or treated"
        }	
        else {
            display in smcl "." _continue
            if mod(`b',50)==0 dis "     `b'"

            qui putmata bsam_id=`2' if `tyear'==. & `3'==`mint', replace
            mata: indicator=smerge(bsam_id, (ori_id, ori_pos))
            mata: OMEGAB=OMEGA[(indicator\rows(OMEGA)),]		

            mata: data = st_data(.,("`1' `cID' `2' `3' `4' `treated' `tyear' `conts'"))
            mata: ATTB = synthdid(data,1,OMEGAB,LAMBDA,`control_opt')
            mata: ATT_b[`b',] = ATTB.Tau
            local ++b
        }
        restore
    }
    mata: se = sqrt((`B'-1)/`B') * sqrt(variance(vec(ATT_b)))
    mata: st_local("se", strofreal(se)) 
}
    	
*--------------------------------------------------------------------------*
* (4) Standard error: placebo
*--------------------------------------------------------------------------*
else if "`vce'"=="placebo" {
    cap set seed `seed'
    local b = 1
    local B = `reps'
    mata: ATT_p = J(`B', 1, .)
	
    /*if (`tr'>=`co')==1 {
        di as err "It is not possible to do Placebo se. Must have more controls than treated units."
        exit 198
    }*/
	
    dis "Placebo replications (`reps'). This may take some time."
    dis "----+--- 1 ---+--- 2 ---+--- 3 ---+--- 4 ---+--- 5"
	
    while `b'<=`B' {
        preserve
        keep `1' `2' `3' `4' `tyear' `conts'
        tempvar r rand id
        qui gen `r'=runiform() in 1/`co'
        bys `2': egen `rand'=sum(`r')
        qui drop if `tyear'!=.        //drop treated units
        egen `id' = group(`rand')     //gen numeric order by runiform variable
		
        local i=1
        forvalues y=`newtr'/`co' {
            qui replace `tyear'=tryears[`i',1] if `id'==`y'
            local ++i
        }

        qui replace `4'=1 if `3'>=`tyear'
        bys `2': egen `treated' = max(`4')
		
        display in smcl "." _continue
        if mod(`b',50)==0 dis "     `b'"
			
        qui putmata psam_id=`2' if `tyear'==. & `3'==`mint', replace
        mata: indicator=smerge(psam_id, (ori_id, ori_pos))
        mata: OMEGAP=OMEGA[(indicator\rows(OMEGA)),]		
		
        mata: data = st_data(.,("`1' `2' `2' `3' `4' `treated' `tyear' `conts'"))
        mata: ATTP = synthdid(data,1,OMEGAP,LAMBDA,`control_opt')
        mata: ATT_p[`b',] = ATTP.Tau
		local ++b
        restore
    }
    mata: se = sqrt((`B'-1)/`B') * sqrt(variance(vec(ATT_p)))
    mata: st_local("se", strofreal(se))
}

*--------------------------------------------------------------------------*
* (5) Standard error: jackknife
*--------------------------------------------------------------------------*
else if "`vce'"=="jackknife" {
    dis "Standard error estimation under construction for staggered adoption"
    local se 0

}


*--------------------------------------------------------------------------*
* (6) Return output
*--------------------------------------------------------------------------*
ereturn local se `se' 
ereturn local ATT `ATT'
    
*Display results
di as text " "
di as text "{c TLC}{hline 8}{c TT}{hline 11}{c TRC}"
di as text "{c |} {bf: ATT}   {c |} " as result %9.5f `ATT'  as text " {c |}"
di as text "{c |} {bf: se}    {c |} " as result %9.5f `se' as text " {c |}"
di as text "{c BLC}{hline 8}{c BT}{hline 11}{c BRC}"   	


*--------------------------------------------------------------------------*
* (7) Graphing
*--------------------------------------------------------------------------*
if "`graph'"=="on" {
    qui tab `tyear'
    local trN=r(r)
    mata: year=LAMBDA[1::`T',(`trN'+1)]
    mata: id=OMEGA[1::`co',(`trN'+1)]
	
	foreach time of local tryear {
        preserve
        mata: weight_lambda_`time'=select(LAMBDA[1::`T',],LAMBDA[rows(LAMBDA),]:==`time')
        clear
        getmata weight_lambda_`time' year, force
        tempfile lambda_weights_`time'
        qui save `lambda_weights_`time''
        clear
        mata: weight_omega_`time'=select(OMEGA[1::`co',],OMEGA[rows(OMEGA),]:==`time')
        getmata weight_omega_`time' id, force
        qui ren id `2'
        tempfile omega_weights_`time'
        qui save `omega_weights_`time''
        restore
    }
		
    local TAU=1
    foreach time of local tryear {
        preserve
        qui keep if `tyear'==. | `tyear'==`time'
        qui levelsof `2' if `tyear'==`time', local(tr_unit)
        qui levelsof `2', local(id2)
        qui count if `tyear'==`time' & `3'==`time'
        local Ntr=r(N)
        qui merge m:1 `3' using `lambda_weights_`time'', nogen
        *qui merge m:1 `2' using `omega_weights_`time'' , nogen		

        mata: Z=J(`N',5,.)

        local i=1
        foreach s of local id2 {
            qui sum `1' if `3'>=`time' & `2'==`s'
            mata: Z[`i',1]=`r(mean)'
            local ++i
        }

        tempvar Y_lambda
        qui gen `Y_lambda'=`1'*weight_lambda		

        local i=1
        foreach s of local id2 {
            qui sum `Y_lambda' if `3'<`time' & `2'==`s'
            mata: Z[`i',2]=`r(mean)' * `r(N)'
            mata: Z[`i',4]=`s'
            local ++i
        }

        mata: Z[,3]=Z[,1]-Z[,2]
        mata: delta_tr=J(1,`Ntr',.)
        local i=1
        foreach s of local tr_unit {
            mata: delta_tr[1,`i']=select(Z[,3],Z[,4]:==`s')
            local ++i
        }	

        mata: Z[,5]=J(`N',1,sum(delta_tr)/`Ntr')-Z[,3]
        clear
        mata: difference=Z[,5]
        mata: state=Z[,4]
        mata: omega=weight_omega_`time'
        getmata difference state, force
       
        local tr_u `tr_u' `tr_unit' 
        foreach s of local tr_u {
            qui drop if state==`s'
        }

        getmata omega, force
        qui drop if state==.
        gen order=_n
        egen order2=axis(order), label(state) //from egenmore ssc install egenmore
        mata: st_local("tau", strofreal(ATT.tau[`TAU',]))

        order diff order2 order state
        *mkmat _all, matrix(a`time')
		
        #delimit ;
        twoway scatter diff order if omega!=0 [aw=omega], msize(tiny)
            || scatter diff order if omega==0, m(X) 
            xlabel(1(1)`co', angle(vertical) labs(tiny) valuelabel)
            yline(`tau', lc(red)) 
            `g1_opt' 
            name(g1_`time', replace)
            legend(off);
        #delimit cr
        restore
        local ++TAU
		
        preserve
        qui merge m:1 `2' using `omega_weights_`time'' , nogen		
        qui keep if `tyear'==. | `tyear'==`time'
        tempvar Y_omega tipo
        qui drop if weight_omega==0
        qui gen `Y_omega'=`1' if weight_omega==.
        qui replace `Y_omega'=`1'*weight_omega if weight_omega!=.
        qui gen `tipo'="Control" if weight_omega!=.
        qui replace `tipo'="Treated" if weight_omega==.
        keep `2' `3' `Y_omega' `tipo'
        qui reshape wide `Y_omega', i(`2' `3') j(`tipo') string
        collapse (sum) `Y_omega'Control (mean) `Y_omega'Treated,  by(`3')

        mata: lambda=weight_lambda_`time'
        getmata lambda, force

        #delimit ;
        twoway line `Y_omega'Control `3', yaxis(2) lp(solid)
    	    || area lambda `3', yaxis(1) lp(solid) ylabel(0(1)5, axis(1)) ysc(off)
            || line `Y_omega'Treated `3', yaxis(2) lp(solid)
            || , 
            xline(`time', lc(red)) legend(order(1 "Control" 2 "Treated") pos(12) col(2))
            `g2_opt'
            name(g2_`time', replace);
        #delimit cr
	restore
    }
}
end

*------------------------------------------------------------------------------*
* (8) Stata Subroutines
*------------------------------------------------------------------------------*
cap program drop _parse_X
program define _parse_X, rclass
syntax varlist [, *]

local valid_X=inlist("`options'", "R", "xsynth", "")
if (`valid_X'==0) {
    dis as error "Control types must be one of {bf:R} or {bf:xsynth}."
    exit 198
}

if ("`options'"=="") local options R
unab conts: `varlist'

return local controls `conts'
return local ctype    `options'
end

*------------------------------------------------------------------------------*
* (9) Mata functions
*------------------------------------------------------------------------------*
mata:
struct results {
    real matrix Omega
    real matrix Lambda
    real matrix tau
    real scalar Tau
}
end

*Main function (synthdid)
*Below assumes data is a matrix with:
* (1) y variable
* (2) group variable (bootstrap fix if necessary)
* (3) orig group variable
* (4) time variable
* (5) treatment variable
* (6) indicator if unit ever treated
* (7) indicator of year treated (if treated)
* (8+) any controls
mata:
    struct results scalar synthdid(matrix data, inference, OMEGA, LAMBDA, controls) {
        //controls: '0' no, '1' synth way, '2' R way
        data  = sort(data, (6,2,4))
        units = panelsetup(data,2)
        NT = panelstats(units)[,3]
        treat=panelsum(data[.,(2,5)],units)
        treat[,1]=treat[,1]/NT
        treat[,2]=1*(treat[,2]:>=1) + 0*(treat[,2]:==1)
        Nco = sum(data[,7]:==.)/NT
        controlID = uniqrows(select(data[.,2],data[,7]:==.))        
        
        //Adjust for controls in xysnth way
        if (cols(data)>7 & controls==1) {
            K = cols(data)
            cdat = data[selectindex(data[,6]:==0),(1,2,4,8..K)]
            cdat = select(cdat, rowmissing(cdat):==0)
            //CAN THIS BE OPTIMIZED FOR FIXED EFFECTS???
            X = cdat[.,4::cols(cdat)]
            NX = cols(X)
            yearFEs = uniqrows(cdat[.,3])
            for (fe=1;fe<=rows(yearFEs);fe++) {
                fevar = cdat[.,3]:==yearFEs[fe]
                X = (X,fevar)
            }
            unitFEs = uniqrows(cdat[.,2])
            for (fe=1;fe<=rows(unitFEs);fe++) {
                fevar = cdat[.,2]:==unitFEs[fe]
                X = (X,fevar)
            }            
            y = cdat[.,1]
            // Estimate regression
            XX = quadcross(X,1 , X,1)
            Xy = quadcross(X,1 , y,0)
            beta = invsym(XX)*Xy
            beta = beta[1::NX]
            X = data[.,8::K]
            data[,1]=data[.,1]-X*beta
        }

        //Find years which change treatment
        trt = select(uniqrows(data[,7]),uniqrows(data[,7]):!=.)
        //Iterate over years, calculating each estimate
        tau    = J(rows(trt),1,.)
        tau_wt = J(1,rows(trt),.)

        if (inference==0) {
            Omega = J(Nco, rows(trt),.)
            Lambda = J(NT, rows(trt),.)
        }
        for(yr=1;yr<=rows(trt);++yr) {
            //trt[yr]
            cond1 = data[,7]:==trt[yr]
            cond2 = data[,7]:==.
            cond = cond1+cond2
            yNtr = sum(cond1)
            yNco = sum(cond2)
            //cond = cond + data[,6]:==.

            ydata = select(data,cond)
            yunits = panelsetup(ydata,2)
            yNT = panelstats(yunits)[,3]
            yNG = panelstats(yunits)[,1]
            yN  = panelstats(yunits)[,2]
            yNtr = yNtr/yNT
            yNco = yNco/yNT
            yTpost = max(ydata[,4])-trt[yr]+1

            pretreat = select(uniqrows(data[,4]),uniqrows(data[,4]):<trt[yr])
            Npre  = rows(pretreat)
            Npost = yNT-Npre

            //Calculate Zeta
            ndiff = yNG*(yNT-1)
            ylag = ydata[1..(yN-1),1]
            ylag = (. \ ylag)

            diff = ydata[.,1]-ylag

            first = mod(0::(yN-1),yNT):==0
            postt = ydata[,4]:>=trt[yr]
            dropc = first+postt+ydata[,6]
            prediff = select(diff,dropc:==0)
            sig_t = sqrt(variance(prediff))

            EtaLambda = 1e-6
            EtaOmega = (yNtr*yTpost)^(1/4)
            yZetaOmega  = EtaOmega*sig_t
            yZetaLambda = EtaLambda*sig_t
            //Generate Y matrices
            ids = uniqrows(ydata[.,2])
            ytreat = ydata[,7]:==trt[yr]
            ytreat=panelsum(ytreat,yunits)
            ytreat=ytreat/yNT

            Y = rowshape(ydata[.,1],yNG)
            Y0 = select(Y,ytreat:==0)
            Y1 = select(Y,ytreat:==1)
            //Generate average of outcomes for each unit over time
            promt = mean(Y0[,(Npre+1)::yNT]')'
            //Calculate input matrices (pre-treatment and averages)
            A_l = Y0[,1..Npre]:-mean(Y0[,1..Npre])
            b_l = promt:-mean(promt)
            A_o = Y0[,1..Npre]':-mean(Y0[,1..Npre]')
            b_o = mean(Y1[.,1..Npre])':-mean(mean(Y1[.,1..Npre])')
	
            //Calculate Tau for t
            if (inference==1) {
                lambda_l = select(LAMBDA'[.,1::Npre],LAMBDA'[,rows(LAMBDA)]:==trt[yr])
                l_o = select(OMEGA'[.,1::yNco],OMEGA'[,rows(OMEGA)]:==trt[yr])
                lambda_o = sum_norm(l_o) //update so prior weights sum to 1
            }
            else {
                lambda_l = J(1,cols(A_l),1/cols(A_l))
                lambda_o = J(1,cols(A_o),1/cols(A_o))
            }
            mindec = (1e-5*sig_t)^2
			
            if (controls==2) {
                K = cols(data)
                A = J((K-7),1,NULL)
                CX = J((K-7),1,NULL)
                n=1
                for (c=8;c<=K;++c) {
                    X = rowshape(ydata[.,c],yNG)
                    CX[n] = &(rowshape(ydata[.,c],yNG))
                    X0 = select(X,ytreat:==0)
                    X1 = select(X,ytreat:==1)
                    A[n] = &((X0[,1..Npre],mean(X0[,(Npre+1)::yNT]')')\(mean(X1[.,1..Npre]),0))
                    n++
                }
				
                maxiter=10000
                vals = J(1, maxiter, .)
 		        beta=J(1,(K-7),0)
                gradbeta = J(1,(K-7),0)
                t=0
                dd=1
				
                eta_o = Npre*yZetaOmega^2
                eta_l = yNco*yZetaLambda^2
			
		        //update wights
                lambda_l = fw(A_l,b_l,lambda_l,eta_l)
                err_l    = (A_l, b_l)*(lambda_l' \ -1)
                lambda_o = fw(A_o,b_o,lambda_o,eta_o)
                err_o    = (A_o, b_o)*(lambda_o' \ -1)	
				
                while (t<maxiter & (t<2 | dd>mindec)) {
                    t++
					
		    for (c=1;c<=(K-7);++c) {
		        gradbeta[c]=-(err_l'*((*A[c])[1..yNco,1..(Npre+1)])*((lambda_l'\-1):/yNco) +
                            err_o'*((*A[c])[1..(yNco+1),1..Npre])'*((lambda_o'\-1):/Npre))
                    }			
                    alpha=1/t
                    beta=beta-alpha*gradbeta

                    //~ contract3
                    C = J(yNco+1,Npre+1,0)
                    for (c=1;c<=(K-7);++c) {
		        C = C + beta[c]*(*A[c])
                    }

                    Ybeta=((Y0[,1..Npre],promt)\(mean(Y1[.,1..Npre]),0))-C
					
                    Ybeta_A_l = Ybeta[1::yNco,1::Npre]:-mean(Ybeta[1::yNco,1::Npre])
                    Ybeta_b_l = Ybeta[1::yNco,Npre+1]:-mean(Ybeta[1::yNco,Npre+1])
                    Ybeta_A_o = Ybeta[1::yNco,1::Npre]':-mean(Ybeta[1::yNco,1::Npre]')
                    Ybeta_b_o = (Ybeta[yNco+1,1::Npre])':-mean((Ybeta[yNco+1,1::Npre])')
				
                    lambda_l = fw(Ybeta_A_l,Ybeta_b_l,lambda_l,eta_l)
                    err_l    = (Ybeta_A_l,Ybeta_b_l)*(lambda_l' \ -1)
                    lambda_o = fw(Ybeta_A_o,Ybeta_b_o,lambda_o,eta_o)
                    err_o    = (Ybeta_A_o,Ybeta_b_o)*(lambda_o' \ -1)
					
                    vals[1,t]=yZetaOmega^2*(lambda_o*lambda_o')+yZetaLambda^2*(lambda_l*lambda_l')+
                              (err_o'*err_o)/Npre+(err_l'*err_l)/yNco
                    if (t>1) dd = vals[1,t-1] - vals[1,t]
                }

                if (inference==0) {
                    Lambda[.,yr] =  (lambda_l' \ J(Npost,1,.))
                    Omega[.,yr] = lambda_o'
                }
				
                Xbeta = J(rows(Y),cols(Y),0)
                for (c=1;c<=(K-7);++c) {
                    Xbeta = Xbeta + beta[c]*(*CX[c])
                }
			  
                tau[yr] = (-lambda_o, J(1,yNtr,1/yNtr))*(Y-Xbeta)*(-lambda_l, J(1,Npost,1/Npost))'
                tau_wt[yr] = yNtr*Npost
            }
			
            if (controls==0 | controls==1) {
                //Find optimal weight matrices
                eta_o = Npre*yZetaOmega^2
                eta_l = yNco*yZetaLambda^2
                lambda_l = lambda(A_l,b_l,lambda_l,eta_l,yZetaLambda,100,mindec)
                //lambda_l
                lambda_l = sspar(lambda_l)
                lambda_l = lambda(A_l, b_l, lambda_l,eta_l,yZetaLambda, 10000,mindec)
                
                lambda_o = lambda(A_o, b_o, lambda_o,eta_o,yZetaOmega, 100,mindec)
                //lambda_o
                lambda_o = sspar(lambda_o)
                lambda_o = lambda(A_o, b_o, lambda_o,eta_o,yZetaOmega, 10000,mindec)
                if (inference==0) {
                    Lambda[.,yr] =  (lambda_l' \ J(Npost,1,.))
                    Omega[.,yr] = lambda_o'
                }
                tau[yr] = (-lambda_o, J(1,yNtr,1/yNtr))*Y*(-lambda_l, J(1,Npost,1/Npost))'
                tau_wt[yr] = yNtr*Npost
            }
        }
        if (inference==0) {
            Omega =  (Omega, controlID)
            Omega =  (Omega \ (trt', .))
            Lambda = (Lambda, uniqrows(data[,4]))
            Lambda = (Lambda \ (trt', .))
        }
        tau_wt = tau_wt/sum(tau_wt')
        ATT = tau_wt*tau
        struct results scalar r
        r.Omega = Omega
        r.Lambda = Lambda
        r.tau = tau
        r.Tau = ATT
        return(r)
    }
end
  
*minimization
mata:
real vector lambda(matrix A, matrix b, matrix x, eta, zeta, maxIter, mindecrease) {    
    row = rows(A)
    col = cols(A)
    vals = J(1, maxIter, .)
    t=0
    dd=1
    
    while (t<maxIter & (t<2 | dd>mindecrease)) {
        t++
        Ax = A * x'	
        hg = (Ax - b)' * A + eta * x
        i = select((1..cols(hg)), colmin(hg :== min(hg)))[1,1]
        dx = -x
        dx[1,i] = 1 - x[1,i]
        v = abs(min(dx))+abs(max(dx))
        if (v==0) {
            x = x
            err = (A, b) * (x' \ -1)
            vals[1,t] = zeta^2 * (x * x') + (err' * err) / row
            if (t>1) {
                dd = vals[1,t-1] - vals[1,t]
            }
        }
        else {
            derr = A[.,i] - Ax
            step = -(hg) * dx' :/ ((derr' * derr) + eta * (dx * dx'))
            conststep = min((1, max((0, step)))) 
            x = x + conststep * dx  
            err = (A, b) * (x' \ -1)
            vals[1,t] = zeta^2 * (x * x') + (err' * err) / row
            if (t>1) {
                dd = vals[1,t-1] - vals[1,t]
            }
        }
    }
    return(x)
}
end


*fw.step 
mata:
real vector fw(matrix A, matrix b, matrix x, eta) {    
    Ax = A * x'	
    hg = (Ax - b)' * A + eta * x
    i = select((1..cols(hg)), colmin(hg :== min(hg)))[1,1]
    dx = -x
    dx[1,i] = 1 - x[1,i]
    v = abs(min(dx))+abs(max(dx))
    if (v==0) {
        x = x
    }
    else {
        derr = A[.,i] - Ax
        step = -(hg) * dx' :/ ((derr' * derr) + eta * (dx * dx'))
        conststep = min((1, max((0, step)))) 
        x = x + conststep * dx  
    }
    return(x)
}
end

*spar function
mata:
    real matrix sspar(matrix V) {
        W = J(1,length(V),.)
        for (i=1; i<=length(V); ++i) {
            W[1,i] = V[1,i] <= max(V)/4 ? 0 : V[1,i]
        }
        W = W :/ sum(W)
        return(W)
    }
end
	
*sum normalize
mata:
    real vector sum_norm(matrix O) {
        sum_o = sum(O)
        if (sum_o!=0) {
            O = O / sum_o
        }
        else {
            O = J(1, cols(O), 1/cols(O)) 
        }
        return(O)
    }
end

*simple merge bt two vectors
mata:
    real matrix smerge(matrix A, matrix B)
{
    v = J(rows(A), 1, .)
    A = (A, v)
    for (i=1; i<=rows(A); i++) {
        for (j=1; j<=rows(B); j++) {
            if (A[i,1]==B[j,1]) A[i,2]=B[j,2]
        }
	}
    A = A[.,2]
    return(A)
}
end	

*for jackknife
mata:
    real vector jackknife(matrix Y, matrix L, matrix O, c, tp, N, T) {
        tau_j = J(N, 1, .)
        ind1 = (1::N)
        for (i=1; i<=N; i++) {
            id = select(ind1, ind1:!=i)
            id2 = select(id, id:<=c)
            t = length(id)-length(id2)
            l_o = sum_norm(O[,id2])
            tau_j[i,1] = (-l_o, J(1, t, 1/t))*Y[(id),1..T]*(-L, J(1, tp, 1/tp))'
        }
        se_j = sqrt(((N-1)/N) * (N - 1) * variance(vec(tau_j)))
        return(se_j)
    }
end



