# Nowcasting dell'occupazione mensile con i job postings Indeed

Dofile principale: **`nowcast_employment_indeed.do`** (Stata 18).
Impostato a partire da `save_indeed_and_prediction_JVR.do`, che resta il
riferimento per la struttura (load Indeed → dataset target → prediction).

## Dati

| file | contenuto | copertura |
|---|---|---|
| `indeed_monthly.dta` | indice job postings online, media mensile | 2020m2–2026m6, DE ES FR IT NL EA21 |
| `DE.dta` | occupazione, migliaia, destagionalizzata | 1992m1–2026m5 |
| `IT.dta` | idem | 2004m1–2026m5 |
| `NL.dta` | idem | 2003m1–2026m6 |
| `ES.dta` | idem | 2012m1–2026m6 |

Il dofile costruisce anche un aggregato **EA4** = somma dell'occupazione dei
quattro paesi (solo mesi in cui tutti sono osservati), accostato all'indice
Indeed EA21. Non è l'area dell'euro: l'approssimazione va tenuta presente.

**Ragged edge.** Indeed arriva a 2026m6; l'occupazione a 2026m5 per DE e IT,
a 2026m6 per NL ed ES. La finestra di nowcasting vero e proprio è quindi di un
mese per DE e IT; oltre l'ultimo mese Indeed si usano proiezioni dirette.

## Impostazione

L'occupazione destagionalizzata è molto persistente e la sua variazione mensile
è rumorosa. La correlazione contemporanea fra variazione mensile
dell'occupazione e di Indeed è alta nel campione pieno (0,55–0,73) ma è
largamente guidata dallo shock Covid: dal 2022 scende a 0,1–0,5. Il segnale
diventa invece nettamente più informativo se **filtrato** e se si guarda a
orizzonti più lunghi (variazioni a 3 e 12 mesi). Da qui la specificazione:

```
g_empl(t+h) = a + b1·g_empl(t-1) + b2·Δ¹log(Indeed)(t) + b3·Δ³log(Indeed)(t) + e
```

stimata in **forma diretta** per ogni orizzonte h = 0…3, così da non dover
prevedere Indeed stesso. Modelli a confronto:

- **RW** – variazione nulla (livello invariato)
- **AR** – sola persistenza
- **ADL** – AR + Indeed, stima paese per paese
- **POOL** – AR + Indeed con effetti fissi di paese (analogo della `xtreg` del
  dofile JVR, ma in tassi di crescita: in livelli la relazione sarebbe spuria)
- **COMBO** – media semplice di AR, ADL, POOL

**Disegno real-time.** A ogni forecast origin `t0` si assume di conoscere
Indeed fino a `t0` e l'occupazione fino a `t0-1`; i modelli sono ristimati su
finestra espansiva usando solo le righe la cui dipendente era già nota in `t0`
(`timem <= t0-h-1`). Tutti i modelli condividono lo stesso campione di stima
(`esample`), altrimenti l'AR — stimabile dal 1992 per la Germania — vincerebbe
il confronto per la maggiore lunghezza del campione e non per l'informazione.

Valutazione ricorsiva da 2023m1 (38–42 origin per cella), RMSE e test di
Diebold–Mariano con SE HAC Newey–West contro **entrambi** i benchmark.

## Risultati principali

RMSE relativo (<1 = il modello con Indeed è migliore del benchmark):

| paese | h | vs AR (ADL / COMBO) | vs RW (ADL / COMBO) |
|---|---|---|---|
| DE | 0 | 0,89 / 0,88 | 0,94 / 0,93 |
| DE | 2 | 0,76 / 0,90 | 1,58 / 1,88 |
| IT | 0 | 1,01 / 0,98 | 0,97 / 0,94 |
| IT | 2 | 1,00 / 0,99 | 0,95 / 0,94 |
| NL | 0 | 0,93 / 0,93 | 1,19 / 1,19 |
| ES | 0 | 1,02 / 0,93 | 0,45 / 0,41 |
| ES | 1 | 1,14 / 0,91 | 0,55 / 0,44 |
| EA4 | 1 | 0,86 / 0,82 | 0,80 / 0,77 |
| EA4 | 2 | 0,81 / 0,89 | 0,83 / 0,91 |

Letture:

1. **Indeed batte l'AR quasi ovunque**, in modo statisticamente significativo
   per DE (tutti gli h), NL (tutti gli h) ed EA4 (h ≥ 1). Per IT il guadagno è
   nullo, per ES arriva dal modello pooled.
2. **Il benchmark rilevante non è sempre l'AR.** Per DE e NL le serie sono così
   lisce che il "livello invariato" batte l'AR: contro il RW il contributo di
   Indeed sopravvive solo a h = 0 per DE, e per NL scompare. Questo è il motivo
   per cui il dofile riporta entrambi i confronti — valutare solo contro l'AR
   sopravvaluterebbe il modello.
3. **Il guadagno maggiore è per la Spagna** (RMSE dimezzato rispetto al RW,
   DM significativo a tutti gli orizzonti) e per **l'aggregato EA4**, dove la
   combinazione batte l'AR del 10–20%.
4. Il **pooling** aiuta dove la serie paese è corta o rumorosa (ES), mentre la
   stima paese per paese è migliore per DE. La **combinazione** è la scelta più
   robusta: mai la peggiore, spesso vicina alla migliore.
5. Su orizzonti a 3 e 12 mesi il contenuto informativo di Indeed è molto più
   netto (RMSE fino a −70% rispetto all'AR a 12 mesi): il dofile riporta queste
   regressioni come robustezza.

## Nowcast (origin 2026m6, modello COMBO)

| paese | 2026m6 | 2026m7 | 2026m8 | 2026m9 |
|---|---|---|---|---|
| DE | 45.825 (+0,00%) | 45.834 | 45.845 | 45.858 |
| IT | 24.333 (−0,01%) | 24.351 | 24.387 | 24.427 |
| NL | *9.831 osservato* | 9.840 | 9.852 | 9.863 |
| ES | *22.209 osservato* | 22.274 | 22.334 | 22.386 |
| EA4 | 102.165 (+0,06%) | 102.251 | 102.355 | 102.459 |

Livelli in migliaia di persone. Per NL ed ES il mese 2026m6 è già pubblicato e
serve da verifica: il modello prevedeva +0,032% contro +0,020% osservato (NL) e
+0,282% contro +0,417% osservato (ES).

## Output prodotti

```
output/panel_empl_indeed.dta      panel occupazione + Indeed, trasformazioni
output/oos_results.dta / .csv     previsioni ed errori per origin/orizzonte
output/rmse_table.dta / .csv      RMSE e rapporti per paese e orizzonte
output/nowcast_employment.dta/csv nowcast in tassi e in livelli
graphs/*.png                      Indeed vs occupazione, fit, livelli, RMSE
```

## Parametri

In testa al dofile: `hmax` (orizzonte, default 3), `oos_start` (primo origin,
default 2023m1), `minobs` (default 24), `covid_dum` (dummy lockdown nelle stime
in-sample). `$source` è impostato sulla working directory.

## Nota

I risultati riportati sopra sono stati ottenuti replicando la logica del dofile
in un ambiente senza Stata installato: vanno confermati alla prima esecuzione
di `nowcast_employment_indeed.do`.
