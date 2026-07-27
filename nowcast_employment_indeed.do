*******************************************************************************
* NOWCASTING / FORECASTING DELL'OCCUPAZIONE MENSILE NEI PRINCIPALI PAESI
* DELL'AREA DELL'EURO CON I DATI INDEED SUI JOB POSTINGS ONLINE
*
* Struttura (impostata a partire da save_indeed_and_prediction_JVR.do):
*   0) Setup e parametri
*   1) Costruzione del panel: occupazione (DE, IT, NL, ES) + aggregato EA4
*      + indice Indeed mensile
*   2) Trasformazioni, ragged edge e variabili esplicative
*   3) Analisi descrittiva e correlazioni dinamiche
*   4) Stime in-sample: bridge/ADL paese per paese + panel FE (come nel JVR)
*   5) Valutazione pseudo out-of-sample ricorsiva (RMSE, Diebold-Mariano)
*   6) Nowcast / forecast finale in tassi di crescita e in livelli
*   7) Grafici
*
* Logica economica
* ----------------
* L'occupazione mensile e' pubblicata con ritardo (in questo vintage: ultimo
* dato DE e IT 2026m5, NL e ES 2026m6), mentre l'indice Indeed dei job postings
* online e' disponibile con pochi giorni di ritardo (qui fino a 2026m6). Il gap
* informativo ("ragged edge") e' la finestra in cui Indeed puo' essere usato per
* fare nowcasting vero e proprio; oltre l'ultimo mese Indeed si passa a
* proiezioni dirette (direct multi-step), che hanno il vantaggio di non
* richiedere una previsione di Indeed stesso.
*
* Scelta della specificazione
* ---------------------------
* L'occupazione destagionalizzata e' molto persistente e la sua variazione
* mensile e' rumorosa: la variazione mensile grezza di Indeed ha un rapporto
* segnale/rumore basso. Il segnale Indeed diventa informativo se filtrato, per
* cui accanto a D.lind si usa la variazione a 3 mesi S3.lind. Il modello di
* riferimento e' un ADL/bridge in tassi di crescita, stimato in forma diretta
* per ogni orizzonte h. Modelli a confronto:
*   RW    : crescita nulla (livello invariato)
*   AR    : sola persistenza dell'occupazione
*   ADL   : AR + Indeed, stima paese per paese
*   POOL  : AR + Indeed con effetti fissi di paese (come la regressione JVR)
*   COMBO : media semplice di AR, ADL e POOL
*
* Nota sul disegno real-time: per ogni forecast origin t0 si assume di
* conoscere Indeed fino a t0 e l'occupazione fino a t0-1. I modelli sono
* ristimati a ogni origin su finestra espansiva usando solo le osservazioni la
* cui variabile dipendente era gia' nota in t0.
*
* Input : indeed_monthly.dta, DE.dta, IT.dta, NL.dta, ES.dta
* Output: $out/panel_empl_indeed.dta
*         $out/oos_results.dta/.csv, $out/rmse_table.dta/.csv
*         $out/nowcast_employment.dta/.csv
*         $gph/*.png
*******************************************************************************

clear all
set more off
set varabbrev off
version 18.0

*******************************************************************************
* 0) SETUP E PARAMETRI
*******************************************************************************

* --- Cartelle (adattare $source se i dati non sono nella working directory) ---
global source  "`c(pwd)'"
global out     "${source}/output"
global gph     "${source}/graphs"

capture mkdir "$out"
capture mkdir "$gph"

* --- Paesi con serie di occupazione disponibile ---
global countries "DE IT NL ES"

* --- Parametri dell'esercizio ------------------------------------------------
* hmax      : orizzonte massimo in mesi rispetto all'ultimo mese Indeed
*             (h=0 = nowcast del mese gia' coperto da Indeed)
* oos_start : primo forecast origin della valutazione ricorsiva
* minobs    : numero minimo di osservazioni per stimare un modello
* covid_dum : 1 = include una dummy per i mesi di lockdown nelle stime in-sample
global hmax      = 3
global oos_start = tm(2023m1)
global minobs    = 24
global covid_dum = 1

* Set di regressori del modello con Indeed
global XIND "ar1 g_ind g3_ind"

*******************************************************************************
* 1) COSTRUZIONE DEL PANEL
*******************************************************************************

* -----------------------------------------------------------------------------
* 1a) Occupazione: i quattro file paese hanno struttura (anno, mese, PAESE) ma
*     tipi di variabile eterogenei (anno/mese sono float in alcuni file e
*     interi in altri) -> si armonizzano e si impilano in formato long.
* -----------------------------------------------------------------------------
tempfile empl_long
local firstfile = 1

foreach c of global countries {

    use "${source}/`c'.dta", clear

    capture confirm variable `c'
    if _rc {
        display as error "La variabile `c' non esiste in `c'.dta"
        exit 111
    }
    rename `c' empl

    gen int yy    = round(anno)
    gen int mm    = round(mese)
    gen int timem = ym(yy, mm)
    format timem %tm

    gen str8 geo = "`c'"

    keep geo timem empl
    order geo timem empl
    drop if missing(empl)
    isid geo timem

    if `firstfile' {
        save "`empl_long'", replace
        local firstfile = 0
    }
    else {
        append using "`empl_long'"
        save "`empl_long'", replace
    }
}

use "`empl_long'", clear
label var empl "Occupazione, migliaia di persone, dato destagionalizzato"

* -----------------------------------------------------------------------------
* 1b) Aggregato "EA4" = somma dell'occupazione dei quattro paesi, calcolato solo
*     sui mesi in cui TUTTI i paesi sono osservati (altrimenti la somma avrebbe
*     salti spuri dovuti alla diversa lunghezza delle serie).
*     NB: EA4 non e' l'area dell'euro. Viene accostato all'indice Indeed EA21
*     come proxy della domanda di lavoro dell'area: l'approssimazione va tenuta
*     presente nella lettura dei risultati.
* -----------------------------------------------------------------------------
local ncty : word count $countries

preserve
    gen double empl_c = empl
    collapse (sum) empl (count) nc = empl_c, by(timem)
    keep if nc == `ncty'
    drop nc
    gen str8 geo = "EA4"
    tempfile ea4
    save "`ea4'", replace
restore

append using "`ea4'"

* -----------------------------------------------------------------------------
* 1c) Indeed mensile. Il file contiene gia' timem in formato %tm.
*     EA21 viene duplicato con etichetta EA4 per agganciarlo all'aggregato.
* -----------------------------------------------------------------------------
tempfile indeed_m
preserve
    use "${source}/indeed_monthly.dta", clear
    keep geo timem indeed
    format timem %tm
    replace geo = "EA21" if geo == "EA"
    isid geo timem

    expand 2 if geo == "EA21", gen(dup)
    replace geo = "EA4" if dup == 1
    drop dup

    * geo viene portato alla stessa lunghezza usata nel dataset di occupazione
    gen str8 geo8 = geo
    drop geo
    rename geo8 geo
    order geo timem indeed

    save "`indeed_m'", replace
restore

merge 1:1 geo timem using "`indeed_m'", nogen keep(master match using)

* si tengono solo i paesi con serie di occupazione (FR ed EA21 non ne hanno)
keep if inlist(geo, "DE", "IT", "NL", "ES", "EA4")

* -----------------------------------------------------------------------------
* 1d) Estensione del calendario fino a (ultimo mese Indeed + hmax), in modo che
*     le righe di previsione esistano gia' nel dataset.
* -----------------------------------------------------------------------------
encode geo, gen(cid)

qui summarize timem if !missing(indeed)
local T_indeed = r(max)
local T_end    = `T_indeed' + $hmax

qui levelsof cid, local(cids)
foreach c of local cids {
    qui count if cid == `c' & timem == `T_end'
    if r(N) == 0 {
        local newn = _N + 1
        qui set obs `newn'
        qui replace cid   = `c'     in `newn'
        qui replace timem = `T_end' in `newn'
    }
}

tsset cid timem
tsfill, full

* geo viene ricostruito dalle etichette di cid (le righe aggiunte l'hanno vuoto)
drop geo
decode cid, gen(geo_tmp)
gen str8 geo = geo_tmp
drop geo_tmp
format timem %tm
sort cid timem

*******************************************************************************
* 2) TRASFORMAZIONI, RAGGED EDGE E VARIABILI ESPLICATIVE
*******************************************************************************

tsset cid timem

gen double lempl = 100*ln(empl)
gen double lind  = 100*ln(indeed)
label var lempl "100*log(occupazione)"
label var lind  "100*log(indice Indeed)"

* --- variabile obiettivo: crescita mensile dell'occupazione (in %) -----------
gen double g_empl = D.lempl
label var g_empl "Occupazione, var. % mensile"

* --- persistenza: unico regressore del benchmark AR --------------------------
* ar1 in t e' l'ultima crescita dell'occupazione nota quando esce Indeed di t,
* coerentemente con il ritardo di pubblicazione dell'occupazione.
gen double ar1 = L.g_empl
label var ar1 "Occupazione, var. % mensile in t-1"

* --- segnale Indeed: variazione mensile e variazione a 3 mesi (filtrata) -----
gen double g_ind   = D.lind
gen double g3_ind  = S3.lind
gen double g12_ind = S12.lind
label var g_ind   "Indeed, var. % mensile"
label var g3_ind  "Indeed, var. % sui 3 mesi"
label var g12_ind "Indeed, var. % sui 12 mesi"

* --- variazioni di medio periodo dell'occupazione (per le descrittive) -------
gen double g3_empl  = S3.lempl
gen double g12_empl = S12.lempl
label var g3_empl  "Occupazione, var. % sui 3 mesi"
label var g12_empl "Occupazione, var. % sui 12 mesi"

* --- dummy lockdown ----------------------------------------------------------
gen byte covid = inrange(timem, tm(2020m3), tm(2020m8))
label var covid "Dummy lockdown 2020m3-2020m8"

* --- campione di stima comune a tutti i modelli -------------------------------
* Le serie di occupazione partono da anni molto diversi (DE dal 1992, ES dal
* 2012) mentre Indeed parte da 2020m2. Se il benchmark AR fosse stimato su
* tutta la storia disponibile e l'ADL solo dal 2020, il confronto fra RMSE
* mescolerebbe l'effetto dell'informazione con quello della lunghezza del
* campione. Tutti i modelli vengono quindi stimati sulle stesse righe: quelle
* in cui sono disponibili sia la persistenza sia il segnale Indeed.
gen byte esample = !missing(ar1) & !missing(g_ind) & !missing(g3_ind)
label var esample "1 = riga utilizzabile da tutti i modelli"

* --- ragged edge: ultimo mese osservato per occupazione e per Indeed ---------
bysort cid: egen double T_empl = max(cond(!missing(empl),   timem, .))
bysort cid: egen double T_ind  = max(cond(!missing(indeed), timem, .))
format T_empl T_ind %tm
gen int gap = T_ind - T_empl
label var T_empl "Ultimo mese con occupazione osservata"
label var T_ind  "Ultimo mese con Indeed osservato"
label var gap    "Ampiezza del ragged edge (mesi)"

display _n as text "{hline 78}"
display as result "Copertura delle serie e ragged edge"
display as text "{hline 78}"
preserve
    keep if timem == `T_indeed'
    keep geo T_empl T_ind gap
    format T_empl T_ind %tm
    list geo T_empl T_ind gap, noobs sep(0) abbrev(12)
restore

compress
save "${out}/panel_empl_indeed.dta", replace

*******************************************************************************
* 3) ANALISI DESCRITTIVA E CORRELAZIONI DINAMICHE
*******************************************************************************

* le egen per panel qui sopra hanno riordinato i dati: si ripristina l'ordine
* richiesto dagli operatori di serie storica
sort cid timem
tsset cid timem

display _n as text "{hline 78}"
display as result "Statistiche descrittive (campione Indeed: da 2020m2)"
display as text "{hline 78}"

foreach c in $countries EA4 {
    display _n as result "--- `c' ---"
    qui summarize g_empl if geo=="`c'" & timem>=tm(2020m2)
    display as text "  Occupazione, var. % mensile : media " %6.3f r(mean) ///
        "   sd " %6.3f r(sd) "   N " %4.0f r(N)
    qui summarize g_ind if geo=="`c'" & timem>=tm(2020m2)
    display as text "  Indeed, var. % mensile      : media " %6.3f r(mean) ///
        "   sd " %6.3f r(sd) "   N " %4.0f r(N)
}

* --- correlogramma incrociato: quanto anticipa Indeed? -----------------------
display _n as text "{hline 78}"
display as result "corr( occupazione var.% in t , Indeed var.% in t-k )"
display as text "{hline 78}"
display as text "  paese" _col(14) "k=0" _col(24) "k=1" _col(34) "k=2" ///
    _col(44) "k=3" _col(54) "k=6"

foreach c in $countries EA4 {
    foreach k in 0 1 2 3 6 {
        local r`k' = .
        qui count if geo=="`c'" & !missing(g_empl) & !missing(L`k'.g_ind)
        if r(N) > 3 {
            qui correlate g_empl L`k'.g_ind if geo=="`c'"
            local r`k' = r(rho)
        }
    }
    display as text "  `c'" _col(14) %5.2f `r0' _col(24) %5.2f `r1' ///
        _col(34) %5.2f `r2' _col(44) %5.2f `r3' _col(54) %5.2f `r6'
}

* --- lo stesso su orizzonti piu' lunghi, dove il rapporto segnale/rumore
*     dell'indicatore e' molto piu' favorevole --------------------------------
display _n as text "{hline 78}"
display as result "corr fra var. % a 3 e a 12 mesi di occupazione e Indeed"
display as text "{hline 78}"
foreach c in $countries EA4 {
    local c3  = .
    local c12 = .
    qui count if geo=="`c'" & !missing(g3_empl) & !missing(g3_ind)
    if r(N) > 3 {
        qui correlate g3_empl g3_ind if geo=="`c'"
        local c3 = r(rho)
    }
    qui count if geo=="`c'" & !missing(g12_empl) & !missing(g12_ind)
    if r(N) > 3 {
        qui correlate g12_empl g12_ind if geo=="`c'"
        local c12 = r(rho)
    }
    display as text "  `c'" _col(14) "3 mesi: " %5.2f `c3' ///
        _col(34) "12 mesi: " %5.2f `c12'
}

*******************************************************************************
* 4) STIME IN-SAMPLE
*******************************************************************************

local covidctrl ""
if $covid_dum == 1 local covidctrl "covid"

* -----------------------------------------------------------------------------
* 4a) Equazioni bridge/ADL paese per paese, orizzonte h=0 (nowcast del mese
*     gia' coperto da Indeed). SE HAC di Newey-West per l'autocorrelazione
*     residua. La stima e' fatta su un solo paese alla volta perche' newey non
*     accetta dati in formato panel.
* -----------------------------------------------------------------------------
foreach c in $countries EA4 {
    display _n as text "{hline 78}"
    display as result "ADL h=0 - `c' : g_empl(t) su ar1, Indeed(t)"
    display as text "{hline 78}"
    preserve
        qui keep if geo=="`c'"
        qui tsset timem
        capture noisily newey g_empl $XIND `covidctrl', lag(3)
        if _rc == 0 estimates store ADL_`c'
    restore
}

* -----------------------------------------------------------------------------
* 4b) Versione panel con effetti fissi di paese e SE cluster.
*     E' l'analogo della regressione JVR del dofile di riferimento, riportata
*     pero' in tassi di crescita: i livelli di occupazione non sono
*     confrontabili fra paesi e non sono stazionari, quindi una xtreg in livelli
*     produrrebbe una relazione spuria.
* -----------------------------------------------------------------------------
xtset cid timem

display _n as text "{hline 78}"
display as result "Panel FE (DE, IT, NL, ES) - g_empl(t) su ar1 e Indeed(t)"
display as text "{hline 78}"
xtreg g_empl $XIND `covidctrl' if geo!="EA4", fe vce(cluster cid)
estimates store POOL_FE

* significativita' congiunta del blocco Indeed
test g_ind g3_ind

* --- robustezza 1: esclusione dei mesi di lockdown ---------------------------
display _n as text "{hline 78}"
display as result "Robustezza - Panel FE esclusi i mesi 2020m3-2020m8"
display as text "{hline 78}"
xtreg g_empl $XIND if geo!="EA4" & covid==0, fe vce(cluster cid)
test g_ind g3_ind

* --- robustezza 2: orizzonti a 3 e 12 mesi -----------------------------------
* Su queste trasformazioni il contenuto informativo di Indeed e' molto piu'
* netto che sulla variazione mensile.
display _n as text "{hline 78}"
display as result "Robustezza - Panel FE su var. % a 3 mesi"
display as text "{hline 78}"
xtreg g3_empl L3.g3_empl g3_ind if geo!="EA4", fe vce(cluster cid)

display _n as text "{hline 78}"
display as result "Robustezza - Panel FE su var. % a 12 mesi"
display as text "{hline 78}"
xtreg g12_empl L12.g12_empl g12_ind if geo!="EA4", fe vce(cluster cid)

*******************************************************************************
* 5) VALUTAZIONE PSEUDO OUT-OF-SAMPLE RICORSIVA
*
* Per ogni forecast origin t0 e ogni orizzonte h si assume di conoscere:
*   - Indeed fino a t0 incluso;
*   - l'occupazione fino a t0-1 (ritardo di pubblicazione di un mese).
* Il target e' la variazione dell'occupazione in t0+h. I modelli sono stimati in
* forma diretta sulle sole righe la cui dipendente era gia' nota in t0, cioe'
* con timem <= t0-h-1: la finestra e' espansiva e rispetta la disponibilita'
* reale dell'informazione.
*******************************************************************************

use "${out}/panel_empl_indeed.dta", clear
tsset cid timem

qui summarize timem if !missing(g_empl)
local T_last = r(max)

tempname pf
tempfile oosfile
postfile `pf' str8 geo byte h int torigin int ttarget double actual ///
    double f_rw double f_ar double f_adl double f_pool ///
    using "`oosfile'", replace

forvalues h = 0/$hmax {

    * dipendente al passo h: variazione dell'occupazione in t+h
    capture drop dvh
    if `h' == 0  qui gen double dvh = g_empl
    else         qui gen double dvh = F`h'.g_empl

    forvalues t0 = $oos_start/`T_last' {

        * ultima data di stima ammessa in tempo reale
        local trainend = `t0' - `h' - 1

        * --- POOL: stimato una volta per ogni coppia (h, t0) sui 4 paesi -----
        capture drop __xbp
        local pool_ok = 0
        capture qui regress dvh $XIND i.cid ///
            if timem <= `trainend' & geo != "EA4" & esample==1
        if _rc == 0 {
            if e(N) >= $minobs {
                qui predict double __xbp, xb
                local pool_ok = 1
            }
        }

        foreach c in $countries EA4 {

            * il target deve essere osservato e i regressori disponibili in t0
            qui count if geo=="`c'" & timem==`t0' & !missing(dvh) & ///
                !missing(ar1, g_ind, g3_ind)
            if r(N) == 0 continue

            qui summarize dvh if geo=="`c'" & timem==`t0', meanonly
            local actual = r(mean)

            * --- RW: variazione nulla, cioe' livello invariato --------------
            local f_rw = 0

            * --- AR: sola persistenza ---------------------------------------
            local f_ar = .
            capture drop __xba
            capture qui regress dvh ar1 ///
                if geo=="`c'" & timem <= `trainend' & esample==1
            if _rc == 0 {
                if e(N) >= $minobs {
                    qui predict double __xba, xb
                    qui summarize __xba if geo=="`c'" & timem==`t0', meanonly
                    if r(N) > 0 local f_ar = r(mean)
                }
            }

            * --- ADL: persistenza + Indeed, stima paese per paese -----------
            local f_adl = .
            capture drop __xbd
            capture qui regress dvh $XIND ///
                if geo=="`c'" & timem <= `trainend' & esample==1
            if _rc == 0 {
                if e(N) >= $minobs {
                    qui predict double __xbd, xb
                    qui summarize __xbd if geo=="`c'" & timem==`t0', meanonly
                    if r(N) > 0 local f_adl = r(mean)
                }
            }

            * --- POOL: pendenze comuni + effetto fisso di paese -------------
            * L'aggregato EA4 non entra nella stima pooled (e' la somma degli
            * altri panel) e quindi non ha previsione POOL.
            local f_pool = .
            if `pool_ok' == 1 & "`c'" != "EA4" {
                qui summarize __xbp if geo=="`c'" & timem==`t0', meanonly
                if r(N) > 0 local f_pool = r(mean)
            }

            post `pf' ("`c'") (`h') (`t0') (`t0'+`h') (`actual') ///
                (`f_rw') (`f_ar') (`f_adl') (`f_pool')
        }
    }
}

postclose `pf'

* -----------------------------------------------------------------------------
* 5a) Errori di previsione e RMSE
* -----------------------------------------------------------------------------
use "`oosfile'", clear
format torigin ttarget %tm

* combinazione: media semplice dei modelli stimati disponibili (RW escluso)
egen double f_combo = rowmean(f_ar f_adl f_pool)

foreach m in rw ar adl pool combo {
    gen double e_`m' = actual - f_`m'
    label var e_`m' "Errore di previsione - modello `m'"
}

label var actual "Occupazione, var. % mensile realizzata"
save "${out}/oos_results.dta", replace
export delimited using "${out}/oos_results.csv", replace

preserve
    foreach m in rw ar adl pool combo {
        gen double se_`m' = e_`m'^2
    }
    gen double nobs = !missing(se_ar)
    collapse (mean) se_rw se_ar se_adl se_pool se_combo (sum) n = nobs, ///
        by(geo h)
    foreach m in rw ar adl pool combo {
        gen double rmse_`m' = sqrt(se_`m')
        drop se_`m'
    }
    * rapporti rispetto al benchmark AR: <1 significa che il modello lo batte
    foreach m in rw adl pool combo {
        gen double rel_`m' = rmse_`m'/rmse_ar
    }
    * rapporti rispetto al random walk. Sono necessari perche' per le serie
    * piu' lisce (DE, NL) la variazione mensile e' quasi imprevedibile e il
    * "livello invariato" batte l'AR: valutare solo contro l'AR sopravvaluterebbe
    * il contributo dell'indicatore.
    foreach m in ar adl pool combo {
        gen double relrw_`m' = rmse_`m'/rmse_rw
    }
    order geo h n rmse_rw rmse_ar rmse_adl rmse_pool rmse_combo ///
        rel_rw rel_adl rel_pool rel_combo ///
        relrw_ar relrw_adl relrw_pool relrw_combo
    format rmse_*  %7.4f
    format rel_*   %5.2f
    format relrw_* %5.2f
    sort geo h

    display _n as text "{hline 78}"
    display as result "RMSE out-of-sample - occupazione, var. % mensile"
    display as text "forecast origin a partire da " %tm $oos_start ///
        ", finestra di stima espansiva"
    display as text "{hline 78}"
    list geo h n rmse_rw rmse_ar rmse_adl rmse_pool rmse_combo, ///
        noobs sepby(geo) abbrev(10)

    display _n as text "{hline 78}"
    display as result "RMSE relativi al benchmark AR (<1 = miglioramento)"
    display as text "{hline 78}"
    list geo h n rel_rw rel_adl rel_pool rel_combo, noobs sepby(geo) abbrev(10)

    display _n as text "{hline 78}"
    display as result "RMSE relativi al random walk (<1 = miglioramento)"
    display as text "benchmark piu' severo per DE e NL, dove la variazione"
    display as text "mensile dell'occupazione e' quasi imprevedibile"
    display as text "{hline 78}"
    list geo h n relrw_ar relrw_adl relrw_pool relrw_combo, ///
        noobs sepby(geo) abbrev(11)

    save "${out}/rmse_table.dta", replace
    export delimited using "${out}/rmse_table.csv", replace
restore

* -----------------------------------------------------------------------------
* 5b) Test di Diebold-Mariano dei modelli con Indeed contro i due benchmark.
*     d = e_BENCH^2 - e_MOD^2 ; d>0 favorevole al modello con Indeed.
*     t di Student sulla media di d con SE HAC di Newey-West, lag = h+1.
*     Il test viene ripetuto contro l'AR e contro il random walk perche' per
*     alcuni paesi il benchmark rilevante e' il secondo.
* -----------------------------------------------------------------------------
foreach bench in ar rw {

    display _n as text "{hline 78}"
    display as result "Diebold-Mariano contro il benchmark `bench'"
    display as text "d = e_`bench'^2 - e_MOD^2 ; d>0 favorevole al modello con Indeed"
    display as text "{hline 78}"
    display as text "  paese" _col(14) "h" _col(20) "modello" _col(34) ///
        "media d" _col(48) "t HAC" _col(60) "p-value"

    foreach c in $countries EA4 {
        forvalues h = 0/$hmax {
            foreach m in adl pool combo {
                preserve
                    qui keep if geo=="`c'" & h==`h'
                    qui drop if missing(e_`bench') | missing(e_`m')
                    if _N > 10 {
                        qui gen double d_loss = e_`bench'^2 - e_`m'^2
                        qui tsset ttarget
                        capture qui newey d_loss, lag(`=`h'+1')
                        if _rc == 0 {
                            local b = _b[_cons]
                            local s = _se[_cons]
                            if `s' > 0 & `s' < . {
                                local t = `b'/`s'
                                local p = 2*ttail(e(df_r), abs(`t'))
                                display as text "  `c'" _col(14) `h' _col(20) ///
                                    "`m'" _col(34) %9.5f `b' _col(48) %6.2f ///
                                    `t' _col(60) %6.3f `p'
                            }
                        }
                    }
                restore
            }
        }
    }
}

*******************************************************************************
* 6) NOWCAST / FORECAST FINALE
*
* Origin = ultimo mese con Indeed disponibile. Si producono i tassi di crescita
* previsti per T0, ..., T0+hmax e li si cumula sui livelli a partire
* dall'ultimo dato di occupazione pubblicato.
*******************************************************************************

use "${out}/panel_empl_indeed.dta", clear
tsset cid timem

qui summarize timem if !missing(indeed)
local T0 = r(max)

tempname pf2
tempfile fcfile
postfile `pf2' str8 geo byte h int ttarget double f_ar double f_adl ///
    double f_pool using "`fcfile'", replace

forvalues h = 0/$hmax {

    capture drop dvh
    if `h' == 0  qui gen double dvh = g_empl
    else         qui gen double dvh = F`h'.g_empl

    * --- POOL su tutto il campione disponibile ---------------------------
    capture drop __xbp
    local pool_ok = 0
    capture qui regress dvh $XIND i.cid if geo != "EA4" & esample==1
    if _rc == 0 {
        if e(N) >= $minobs {
            qui predict double __xbp, xb
            local pool_ok = 1
        }
    }

    foreach c in $countries EA4 {

        local f_ar = .
        capture drop __xba
        capture qui regress dvh ar1 if geo=="`c'" & esample==1
        if _rc == 0 {
            if e(N) >= $minobs {
                qui predict double __xba, xb
                qui summarize __xba if geo=="`c'" & timem==`T0', meanonly
                if r(N) > 0 local f_ar = r(mean)
            }
        }

        local f_adl = .
        capture drop __xbd
        capture qui regress dvh $XIND if geo=="`c'" & esample==1
        if _rc == 0 {
            if e(N) >= $minobs {
                qui predict double __xbd, xb
                qui summarize __xbd if geo=="`c'" & timem==`T0', meanonly
                if r(N) > 0 local f_adl = r(mean)
            }
        }

        local f_pool = .
        if `pool_ok' == 1 & "`c'" != "EA4" {
            qui summarize __xbp if geo=="`c'" & timem==`T0', meanonly
            if r(N) > 0 local f_pool = r(mean)
        }

        post `pf2' ("`c'") (`h') (`T0'+`h') (`f_ar') (`f_adl') (`f_pool')
    }
}

postclose `pf2'

* --- si riportano le previsioni sul panel, allineate alla data target --------
tempfile fcmerge
preserve
    use "`fcfile'", clear
    egen double f_combo = rowmean(f_ar f_adl f_pool)
    rename ttarget timem
    rename f_ar    ghat_ar
    rename f_adl   ghat_adl
    rename f_pool  ghat_pool
    rename f_combo ghat_combo
    drop h
    isid geo timem
    save "`fcmerge'", replace
restore

capture drop dvh
capture drop __xbp
capture drop __xba
capture drop __xbd

* geo puo' essere stato compresso a stringa piu' corta: si allinea alla
* lunghezza usata dal postfile prima del merge
capture recast str8 geo

merge 1:1 geo timem using "`fcmerge'", nogen keep(master match)

sort cid timem
tsset cid timem

label var ghat_ar    "Var. % mensile prevista - AR"
label var ghat_adl   "Var. % mensile prevista - ADL"
label var ghat_pool  "Var. % mensile prevista - POOL"
label var ghat_combo "Var. % mensile prevista - COMBO"

* -----------------------------------------------------------------------------
* 6a) Dai tassi di crescita ai livelli.
*     La previsione parte dall'ultimo livello pubblicato e viene incatenata
*     mese per mese. Dove l'occupazione e' gia' osservata il livello resta
*     quello effettivo: per NL ed ES l'orizzonte h=0 e' gia' coperto dal dato
*     pubblicato, quindi la catena parte da h=1.
*     Il replace e' sequenziale nell'ordine di tsset: L. rilegge il valore del
*     mese precedente gia' aggiornato (stessa logica del dofile JVR).
* -----------------------------------------------------------------------------
foreach m in ar adl pool combo {
    gen double empl_`m' = empl
    replace empl_`m' = L.empl_`m'*exp(ghat_`m'/100) ///
        if missing(empl) & !missing(ghat_`m') & !missing(L.empl_`m')
    label var empl_`m' "Occupazione prevista, migliaia - modello `m'"
}

gen byte is_forecast = missing(empl) & !missing(ghat_combo)
label var is_forecast "1 = mese previsto (occupazione non ancora pubblicata)"

* -----------------------------------------------------------------------------
* 6b) Tabella di sintesi
* -----------------------------------------------------------------------------
display _n as text "{hline 78}"
display as result "NOWCAST / FORECAST DELL'OCCUPAZIONE"
display as text "ultimo mese Indeed (forecast origin): " %tm `T0'
display as text "is_forecast = 1 -> mese non ancora pubblicato"
display as text "{hline 78}"

preserve
    keep if timem >= `T0' - 2 & timem <= `T0' + $hmax
    keep geo timem empl empl_combo is_forecast ghat_ar ghat_adl ghat_pool ///
        ghat_combo
    format ghat_* %7.3f
    format empl empl_combo %10.1f
    sort geo timem
    list geo timem empl empl_combo is_forecast ghat_ar ghat_adl ghat_pool ///
        ghat_combo, noobs sepby(geo) abbrev(11)
restore

keep geo cid timem empl indeed lempl lind g_empl g_ind g3_ind g12_ind ///
    g3_empl g12_empl T_empl T_ind gap ghat_ar ghat_adl ghat_pool ghat_combo ///
    empl_ar empl_adl empl_pool empl_combo is_forecast
order geo cid timem empl indeed g_empl g_ind g3_ind ///
    ghat_ar ghat_adl ghat_pool ghat_combo ///
    empl_ar empl_adl empl_pool empl_combo is_forecast

save "${out}/nowcast_employment.dta", replace
export delimited using "${out}/nowcast_employment.csv", replace

*******************************************************************************
* 7) GRAFICI
*******************************************************************************

use "${out}/nowcast_employment.dta", clear
tsset cid timem

* --- 7a) Indeed e occupazione, indici 2020m2 = 100 ---------------------------
foreach c in $countries EA4 {
    preserve
        qui keep if geo=="`c'" & timem>=tm(2020m2)
        qui summarize empl if timem==tm(2020m2), meanonly
        local ne = r(N)
        local base_e = r(mean)
        qui summarize indeed if timem==tm(2020m2), meanonly
        local ni = r(N)
        local base_i = r(mean)
        if `ne' > 0 & `ni' > 0 {
            gen double empl_idx = 100*empl/`base_e'
            gen double ind_idx  = 100*indeed/`base_i'
            twoway (line ind_idx timem, lcolor(navy) lwidth(medthick)) ///
                   (line empl_idx timem, lcolor(cranberry) ///
                        lwidth(medthick) yaxis(2)), ///
                title("`c': job postings Indeed e occupazione") ///
                subtitle("indici, 2020m2 = 100") ///
                ytitle("Indeed", axis(1)) ytitle("Occupazione", axis(2)) ///
                xtitle("") ///
                legend(order(1 "Indeed (asse sx)" 2 "Occupazione (asse dx)") ///
                    rows(1) position(6)) ///
                graphregion(color(white)) name(idx_`c', replace)
            capture graph export "${gph}/indeed_vs_empl_`c'.png", ///
                replace width(1400)
        }
    restore
}

* --- 7b) Var. % mensile: osservata e stimata dal modello ADL -----------------
foreach c in $countries EA4 {
    preserve
        qui keep if geo=="`c'" & timem>=tm(2020m5)
        capture qui regress g_empl $XIND
        if _rc == 0 {
            qui predict double fit_adl, xb
            twoway (line g_empl timem, lcolor(gs6) lwidth(medthick)) ///
                   (line fit_adl timem, lcolor(navy) lpattern(dash) ///
                        lwidth(medthick)), ///
                title("`c': occupazione, var. % mensile") ///
                subtitle("osservata e stimata dal modello ADL con Indeed") ///
                yline(0, lcolor(gs10)) xtitle("") ytitle("var. % m/m") ///
                legend(order(1 "Osservato" 2 "ADL con Indeed") rows(1) ///
                    position(6)) ///
                graphregion(color(white)) name(fit_`c', replace)
            capture graph export "${gph}/fit_adl_`c'.png", replace width(1400)
        }
    restore
}

* --- 7c) Livelli: storia recente e previsione --------------------------------
foreach c in $countries EA4 {
    preserve
        qui keep if geo=="`c'" & timem>=tm(2024m1)
        qui count if is_forecast==1
        if r(N) > 0 {
            qui summarize timem if !missing(empl), meanonly
            local tlast = r(max)
            twoway (line empl timem, lcolor(gs4) lwidth(medthick)) ///
                   (line empl_combo timem if timem>=`tlast', ///
                        lcolor(cranberry) lpattern(dash) lwidth(medthick)), ///
                title("`c': occupazione, livelli") ///
                subtitle("migliaia di persone; tratteggio = previsione COMBO") ///
                xline(`tlast', lcolor(gs10) lpattern(shortdash)) ///
                xtitle("") ytitle("migliaia") ///
                legend(order(1 "Osservato" 2 "Previsione") rows(1) ///
                    position(6)) ///
                graphregion(color(white)) name(lev_`c', replace)
            capture graph export "${gph}/forecast_level_`c'.png", ///
                replace width(1400)
        }
    restore
}

* --- 7d) RMSE relativi al benchmark AR, per orizzonte ------------------------
capture confirm file "${out}/rmse_table.dta"
if _rc == 0 {
    preserve
        use "${out}/rmse_table.dta", clear
        encode geo, gen(gid)
        twoway (connected rel_adl h, lcolor(navy) mcolor(navy)) ///
               (connected rel_pool h, lcolor(forest_green) ///
                    mcolor(forest_green)) ///
               (connected rel_combo h, lcolor(cranberry) mcolor(cranberry)), ///
            by(gid, title("RMSE relativo al benchmark AR") ///
                subtitle("valutazione ricorsiva; <1 = il modello con Indeed vince") ///
                note("") graphregion(color(white))) ///
            yline(1, lcolor(gs8) lpattern(dash)) ///
            xtitle("orizzonte h (mesi)") ytitle("RMSE / RMSE(AR)") ///
            legend(order(1 "ADL" 2 "POOL" 3 "COMBO") rows(1) position(6)) ///
            name(rmse_rel, replace)
        capture graph export "${gph}/rmse_relative.png", replace width(1600)

        twoway (connected relrw_ar h, lcolor(gs6) mcolor(gs6)) ///
               (connected relrw_adl h, lcolor(navy) mcolor(navy)) ///
               (connected relrw_combo h, lcolor(cranberry) mcolor(cranberry)), ///
            by(gid, title("RMSE relativo al random walk") ///
                subtitle("benchmark del livello invariato; <1 = il modello vince") ///
                note("") graphregion(color(white))) ///
            yline(1, lcolor(gs8) lpattern(dash)) ///
            xtitle("orizzonte h (mesi)") ytitle("RMSE / RMSE(RW)") ///
            legend(order(1 "AR" 2 "ADL" 3 "COMBO") rows(1) position(6)) ///
            name(rmse_relrw, replace)
        capture graph export "${gph}/rmse_relative_rw.png", replace width(1600)
    restore
}

display _n as text "{hline 78}"
display as result "Elaborazione completata."
display as text "  panel    : ${out}/panel_empl_indeed.dta"
display as text "  oos      : ${out}/oos_results.dta , ${out}/rmse_table.csv"
display as text "  nowcast  : ${out}/nowcast_employment.dta (e .csv)"
display as text "  grafici  : ${gph}/"
display as text "{hline 78}"

*******************************************************************************
* FINE
*******************************************************************************
