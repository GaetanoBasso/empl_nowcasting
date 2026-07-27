*******************************************************
* Download e pulizia dati Eurostat e Indeed pubblici
* Plan:
* 1) load Indeed
* 2) dataset posti vacanti EA trimestrale
* 3) prediction JVR su Indeed
*******************************************************

clear all
set more off
version 18.0

* --- Cartelle ---
global source "/home/group/main/892fl/dati"

*******************************************************
* 1) LOAD INDEED
*    Salvata come dataset separato
*******************************************************
import delimited using ${source}/indeed/posting/online/job-postings-headline-index_300626.csv, clear varn(1)
drop __typename postingtype
gen double ddate = daily(datestring, "YMD")
format ddate %td
gen mdate = mofd(ddate)
format mdate %tm
gen qdate = qofd(ddate)
format qdate %tq
rename value indeed
tempfile all
save `all'

* Monthly
use `all', clear
replace countrycode="EA21" if countrycode=="EA"
rename countrycode geo
encode geo, gen(country_id)
keep geo country_id mdate indeed 
rename mdate timem 
collapse (mean) indeed, by(geo country_id timem)
gen time = qofd(dofm(timem))
format time %tq
save $source/indeed/posting/dta/indeed_monthly.dta, replace

* Quarterly
use `all', clear
replace countrycode="EA21" if countrycode=="EA"
rename countrycode geo
encode geo, gen(country_id)
keep geo country_id qdate indeed
rename qdate time
collapse (mean) indeed, by(geo country_id time)
save $source/indeed/posting/dta/indeed_quarterly.dta, replace


*******************************************************
* 2) LOAD SERIE TRIMESTRALE POSTI VACANTI
*    Salvata come dataset separato
*******************************************************
use $source/eurostat/posti_vacanti/dta/jvseu.dta, clear
gen time=yq(anno, trim)
format time %tq
keep if adj=="s"
drop adj
keep if nace=="B-T"
drop nace
keep if size=="tot"
drop size
keep if time>=tq(2019q1)
encode geo, gen(country_id)
keep if inlist(geo, "IT", "DE", "ES", "FR", "NL", "EA")
replace geo="EA21" if geo=="EA"
drop anno trim
rename value JVR
drop index
//Aggiunta (SR) per vedere qual è l'ultimo trimestre valorizzato da eurostat --> mi serve dopo per le proiezioni
bys geo: gen n=_n
bys geo: gen x=1 if n==_N
gen last_date=time if x==1
bys geo: replace last_date=last_date[_N] if last_date[_N-1]==.

format last_date %tq
drop n x
tempfile jvr_q
save `jvr_q'

*******************************************************
* 3) Prediction JVR su Indeed
*******************************************************
use `jvr_q', clear 
drop country_id
merge 1:1 geo time using $source/indeed/posting/dta/indeed_quarterly.dta, nogen keep(matched using) keepusing(indeed)
encode geo, gen(country_id)
global last_date=last_date
format last_date %tq
gen anno=year(dofq(time))
gen trim=quarter(dofq(time))

* Panel estimation on quarterly data
xtset country_id time
xtreg JVR indeed i.time, fe vce(cluster country_id)
* Out-of-sample prediction at quarterly level
predict double JVRhat_q, xb
tempfile qpred
gen delta=JVRhat/l.JVRhat-1
replace JVRhat=JVR if time==tq(2026q1)
replace JVRhat=l.JVRhat*(1+delta) if time>tq(2026q1)
replace JVRhat=. if time<tq(2026q1)
keep geo time anno trim JVR JVRhat_q indeed
save $source/indeed/posting/dta/jvrq_indeedq.dta, replace

