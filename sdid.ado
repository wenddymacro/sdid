*! sdid: Synthetic Difference in Difference
*! Version 0.1.0 January 25, 2022
*! Author: Pailañir Daniel, Clarke Damian
*! dpailanir@fen.uchile.cl, dclarke@fen.uchile.cl

cap program drop sdid
program sdid, eclass
version 13.0
	
#delimit ;
    syntax varlist(min=4 numeric), //vce(string)
    [
	seed(integer 0)
    breps(integer 0)
    ]
    ;
#delimit cr  

*--------------------------------------------------------*
*- Create some temporal variables and locals            -*
*--------------------------------------------------------*
tokenize `varlist'
tempvar id id2 diff tr
egen `id' = group(`2')

qui xtset `id' `3'
local N    = r(imax) //number of units
local Tmin = r(tmin) //t min
local T    = r(tmax) //t max

qui tab `id' if `4'==1
local Ntr = r(r)         //number of treated units
local N0  = `N' - `Ntr'  //number of control units

qui tab `3' if `4'==1
local Tpost  = r(r)             //number of post times
local T0     = `T'  - `Tpost'   //max time of control
local Tobs   = `T'  - `Tmin' +1 //number of times
local Tpre   = `T0' - `Tmin' +1 //number of pre times
local Ttrmin = `T0' + 1         //first year of treatment

di as text "                          "
di as text "{c TLC}{hline 26}{c TT}{hline 6}{c TRC}"
di as text "{c |} Number of units          {c |} `N'   {c |}"
di as text "{c |} Number of times          {c |} `Tobs'   {c |}"
di as text "{c |} Smallest unit of time    {c |} `Tmin' {c |}"
di as text "{c |} Larger unit of time      {c |} `T' {c |}"
di as text "{c |} Number of treated units  {c |} `Ntr'    {c |}"
di as text "{c |} Number of control units  {c |} `N0'   {c |}"
di as text "{c |} Number of post-periods   {c |} `Tpost'   {c |}"
di as text "{c |} Number of pre-periods    {c |} `Tpre'   {c |}"
di as text "{c |} Maximun time of control  {c |} `T0' {c |}"
di as text "{c |} First time of treatment  {c |} `Ttrmin' {c |}"
di as text "{c BLC}{hline 26}{c BT}{hline 6}{c BRC}"

*-------------------------------------------------------*
*- Calculate \zeta                                     -*
*-------------------------------------------------------*
bys `id' : egen `tr' = mean(`4')
qui replace `tr' = 1 if `tr'!=0

local EtaOmega  = (`Ntr' * `Tpost')^(1/4)
local EtaLambda = 1e-6
qui gen `diff' = `1' - L.`1'
qui sum `diff' if `3'<=`T0' & `tr'==0
local sig = r(sd)

local ZetaOmega  = `EtaOmega'  * `sig' 
local ZetaLambda = `EtaLambda' * `sig'

*-------------------------------------------------------*
*- Preparing data                                      -*
*-------------------------------------------------------*
*original data
tempfile data
qui save "`data'"

qui levelsof `3', local(times) //local of all times
qui levelsof `3' if `3'<=`T0', local(timespre) //local of pre times

*matrix of control units
qui keep if `tr'==0
keep `1' `id' `3'
qui levelsof `3', local(times) //local of all times
qui levelsof `3' if `3'<=`T0', local(timespre) //local of pre times
qui reshape wide `1', i(`id') j(`3')
mkmat _all, matrix(Y0) //matrix of control units Y0

*matrix of treated units
use `data', clear
qui keep if `tr'==1
keep `1' `id' `3'
qui reshape wide `1', i(`id') j(`3')
mkmat _all, matrix(Y1)

*matrix of control and treated units
matrix Y = (Y0 \ Y1) 
clear
qui svmat Y
drop Y1
gen id = _n

local i=2
foreach n of local times {
    ren Y`i' t`n'
    local ++i
}

*data for estimator
mkmat _all, matrix(Yall)
mata : Yall = st_matrix("Yall")

egen promt = rowmean(t`Ttrmin'-t`T')
drop t`Ttrmin'-t`T' //drop post periods

local r=`N'+1
qui set obs `r'
  
forvalues t=`Tmin'/`T0' {
    qui sum     t`t' if id>`N0'
    qui replace t`t' = r(mean) in `r'
}

qui drop if id>`N0' & id!=. //drop treated units
mkmat _all, matrix(Y)

*-------------------------------------------------------*
*Matrices for optimization
*-------------------------------------------------------*
*Matrix A & b : Lambda 
clear
qui svmat Y, names(col)

local vr `timespre' promt
foreach t of local vr {
    if "`t'"=="promt" local n ""
    if "`t'"!="promt" local n "t"
    qui sum `n'`t' if id<=`N0'
    qui replace `n'`t' = `n'`t' - r(mean) 
}

qui keep in 1/`N0'
mkmat promt, matrix(b_l)
mkmat t`Tmin'-t`T0', matrix(A_l)
local col_l = colsof(A_l)
local row_l = rowsof(A_l)
mata: A_l = st_matrix("A_l")
mata: b_l = st_matrix("b_l")

*Matrix A & b : Omega
clear
qui svmat Y, names(col)
drop promt id
gen id = _n
qui reshape long t, i(id) j(a)
qui reshape wide t, i(a) j(id)
drop a

local max=`N0'+1
forvalues t=1/`max'  {
    qui sum t`t'
    qui replace t`t' = t`t' - r(mean)
}

mkmat t`max', matrix(b_o)
mkmat t1-t`N0', matrix(A_o)
local col_o = colsof(A_o)
local row_o = rowsof(A_o)
mata : A_o = st_matrix("A_o")
mata : b_o = st_matrix("b_o")

*eta value and omega vector
local eta_o = `row_o' * `ZetaOmega'^2
local eta_l = `row_l' * `ZetaLambda'^2

*eta value and lambda vector
mata : lambda_o = J(1, `col_o', 1 / `col_o')
mata : lambda_l = J(1, `col_l', 1 / `col_l')

*-------------------------------------------------------*
*LAMBDA
*-------------------------------------------------------*
local maxIter=100
local mindecrease=(1e-5 * `sig')^2

mata: lambda_l=lambda(A_l, b_l, lambda_l, `eta_l', `ZetaLambda', `maxIter', `mindecrease')

mata : st_local("maxlambda_l", strofreal(max(lambda_l)))
local cut = `maxlambda_l' / 4
mata : lambda_l = mm_cond(lambda_l :<=`cut', 0, lambda_l) //moremata install, creo
mata : lambda_l = lambda_l :/ sum(lambda_l)

local maxIter=10000
local mindecrease=(1e-5 * `sig')^2

mata: lambda_l=lambda(A_l, b_l, lambda_l, `eta_l', `ZetaLambda', `maxIter', `mindecrease')

*-------------------------------------------------------*
*OMEGA
*-------------------------------------------------------*
local maxIter=100
local mindecrease=(1e-5 * `sig')^2

mata: lambda_o=lambda(A_o, b_o, lambda_o, `eta_o', `ZetaOmega', `maxIter', `mindecrease')

mata : st_local("maxlambda_o", strofreal(max(lambda_o)))
local cut = `maxlambda_o' / 4
mata : lambda_o = mm_cond(lambda_o :<=`cut', 0, lambda_o)
mata : lambda_o = lambda_o :/ sum(lambda_o)

local maxIter=10000
local mindecrease=(1e-5 * `sig')^2

mata: lambda_o=lambda(A_o, b_o, lambda_o, `eta_o', `ZetaOmega', `maxIter', `mindecrease')

*save weights in e(r)
mata: st_matrix("lambda", lambda_l')
mata: st_matrix("omega", lambda_o')
ereturn matrix lambda lambda
ereturn matrix omega  omega

*-------------------------------------------------------*
*TAU
*-------------------------------------------------------*
mata : tau = (-lambda_o, J(1, `Ntr', 1/`Ntr')) * Yall[1..`N',1..`Tobs'] * (-lambda_l, J(1, `Tpost', 1/`Tpost'))'
mata : st_local("tau", strofreal(tau))

mata:tau

*restore original data
use `data', clear

*-------------------------------------------------------*
*VCE : bootstrap
*-------------------------------------------------------*
set seed `seed'
local b = 1
local B = `breps'
mata : tau_b = J(1, `B', .)

while `b'<=`B' {
    preserve
    bsample , cluster(`id') idcluster(`id2')
    bys `id2' : egen `tr'`b' = mean(`4')
    qui replace `tr'`b' = 1 if `tr'`b'!=0

    qui sum `tr'`b'
    if (r(mean)==0 | r(mean)==1) {
        *di "Boot `b' : Nothing to do"
    }
    else {
    di "Boot `b' : Running"
	
    *-------------------------------------------------------*
    *- Calculate \zeta                                     -*
    *-------------------------------------------------------*
    qui xtset `id2' `3'
    local EtaOmega  = (`Ntr' * `Tpost')^(1/4)
    local EtaLambda = 1e-6
    qui gen `diff'`b' = `1' - L.`1'
    qui sum `diff'`b' if `3'<=`T0' & `tr'`b'==0
    local sig = r(sd)
    local ZetaOmega  = `EtaOmega'  * `sig' 
    local ZetaLambda = `EtaLambda' * `sig'
	
    *-------------------------------------------------------*
    *- Preparing data                                      -*
    *-------------------------------------------------------*
    *original bootstrap data
    tempfile data`b'
    qui save "`data`b''"

    qui levelsof `3', local(times) //local of all times
    qui levelsof `3' if `3'<=`T0', local(timespre) //local of pre times

    *matrix of control units
    qui keep if `tr'`b'==0
    keep `1' `id2' `3'
    qui levelsof `3', local(times) //local of all times
    qui levelsof `3' if `3'<=`T0', local(timespre) //local of pre times
    qui reshape wide `1', i(`id2') j(`3')
    mkmat _all, matrix(Y0) //matrix of control units Y0

    *matrix of treated units
    use `data`b'', clear
    qui keep if `tr'`b'==1
    keep `1' `id2' `3'
    qui reshape wide `1', i(`id2') j(`3')
    mkmat _all, matrix(Y1)

    *matrix of control and treated units
    matrix Y = (Y0 \ Y1) 
    clear
    qui svmat Y
    drop Y1
    gen id = _n

    local i=2
    foreach n of local times {
        ren Y`i' t`n'
        local ++i
    }

    *data for estimator
    mkmat _all, matrix(Yall`b')
    mata : Yall`b' = st_matrix("Yall`b'")

    egen promt = rowmean(t`Ttrmin'-t`T')
    drop t`Ttrmin'-t`T' //drop post periods

    local r=`N'+1
    qui set obs `r'
  
    forvalues t=`Tmin'/`T0' {
        qui sum     t`t' if id>`N0'
        qui replace t`t' = r(mean) in `r'
    }

    qui drop if id>`N0' & id!=. //drop treated units
    mkmat _all, matrix(Y)

    *-------------------------------------------------------*
    *Matrices for optimization
    *-------------------------------------------------------*
    *Matrix A & b : Lambda 
    clear
    qui svmat Y, names(col)

    local vr `timespre' promt
    foreach t of local vr {
        if "`t'"=="promt" local n ""
        if "`t'"!="promt" local n "t"
        qui sum `n'`t' if id<=`N0'
        qui replace `n'`t' = `n'`t' - r(mean) 
    }

    qui keep in 1/`N0'
    mkmat promt, matrix(b_l)
    mkmat t`Tmin'-t`T0', matrix(A_l)
    local col_l = colsof(A_l)
    local row_l = rowsof(A_l)
    mata : A_l = st_matrix("A_l")
    mata : b_l = st_matrix("b_l")

    *Matrix A & b : Omega
    clear
    qui svmat Y, names(col)
    drop promt id
    gen id = _n
    qui reshape long t, i(id) j(a)
    qui reshape wide t, i(a) j(id)
    drop a

    local max=`N0'+1
    forvalues t=1/`max'  {
        qui sum t`t'
        qui replace t`t' = t`t' - r(mean)
    }

    mkmat t`max', matrix(b_o)
    mkmat t1-t`N0', matrix(A_o)
    local col_o = colsof(A_o)
    local row_o = rowsof(A_o)
    mata : A_o = st_matrix("A_o")
    mata : b_o = st_matrix("b_o")

    *eta value and omega vector
    local eta_o = `row_o' * `ZetaOmega'^2
    local eta_l = `row_l' * `ZetaLambda'^2

    *eta value and lambda vector
    mata: st_local("sum_o", strofreal(sum(lambda_o)))
    if `sum_o'!=0 {
        mata: lambda_o = lambda_o/`sum_o'
    } 
    else {
        mata: lambda_o = J(1, cols(lambda_o), 1/cols(lambda_o)) 
        mata: lambda_o
    }
	
    *-------------------------------------------------------*
    *LAMBDA
    *-------------------------------------------------------*
    local maxIter=100
    local mindecrease=(1e-5 * `sig')^2

    mata: lambda_l=lambda(A_l, b_l, lambda_l, `eta_l', `ZetaLambda', `maxIter', `mindecrease')

    mata : st_local("maxlambda_l", strofreal(max(lambda_l)))
    local cut = `maxlambda_l' / 4
    mata : lambda_l = mm_cond(lambda_l :<=`cut', 0, lambda_l)
    mata : lambda_l = lambda_l :/ sum(lambda_l)

    local maxIter=10000
    local mindecrease=(1e-5 * `sig')^2

    mata: lambda_l=lambda(A_l, b_l, lambda_l, `eta_l', `ZetaLambda', `maxIter', `mindecrease')

    *-------------------------------------------------------*
    *OMEGA
    *-------------------------------------------------------*
    local maxIter=100
    local mindecrease=(1e-5 * `sig')^2

    mata: lambda_o=lambda(A_o, b_o, lambda_o, `eta_o', `ZetaOmega', `maxIter', `mindecrease')

    mata : st_local("maxlambda_o", strofreal(max(lambda_o)))
    local cut = `maxlambda_o' / 4
    mata : lambda_o = mm_cond(lambda_o :<=`cut', 0, lambda_o)
    mata : lambda_o = lambda_o :/ sum(lambda_o)

    local maxIter=10000
    local mindecrease=(1e-5 * `sig')^2

    mata: lambda_o=lambda(A_o, b_o, lambda_o, `eta_o', `ZetaOmega', `maxIter', `mindecrease')

    *-------------------------------------------------------*
    *TAU
    *-------------------------------------------------------*
    mata: tau_b[1,`b'] = (-lambda_o, J(1, `Ntr', 1/`Ntr'))*Yall`b'[1..`N',1..`Tobs']*(-lambda_l, J(1, `Tpost', 1/`Tpost'))'
    local ++b
    }
    restore
}

mata : se_b = sqrt((`B'-1)/`B') * sqrt(variance(vec(tau_b)))
mata : st_local("se_b", strofreal(se_b))

*Display results and save results
ereturn local se `se_b' 
ereturn local tau `tau'

di as text "  "
di as text "{c TLC}{hline 16}{c TT}{hline 11}{c TRC}"
di as text "{c |} {bf: tau}           {c |} " as result %9.5f `tau'  as text " {c |}"
di as text "{c |} {bf: se bootstrap}  {c |} " as result %9.5f `se_b' as text " {c |}"
di as text "{c BLC}{hline 16}{c BT}{hline 11}{c BRC}"

*Restore original data
use `data', clear

end

mata:
function lambda(matrix A, matrix b, matrix x, eta, zeta, maxIter, mindecrease)

{

row = rows(A)
col = cols(A)
vals = J(1, maxIter, .)
t=0
dd=1

while (t<maxIter & (t<2 | dd>mindecrease)) {
    t=t+1    
    Ax = A * x'	
    hg = (Ax - b)' * A + eta * x
    mini = select((1..cols(hg)), colmin(hg :== min(hg)))	
    i = mini[1,1]
    dx = -x
    dx[1,i] = 1 - x[1,i]
    v = abs(min(dx))+abs(max(dx))

    if (v==0) {
        x = x
        err = (A, b) * (x' \ -1)
        vals[1,t] = zeta^2 * (x * x') + (err' * err) / row
    }
    else {
        derr = A[1..row,i] - Ax
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
			
