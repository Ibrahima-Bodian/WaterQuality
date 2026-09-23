# ==============================================================================
#  Projet WaterQuality - M1 DS4SC - Phase 2 (Modeling)
#  Profilage des sources et generation du dictionnaire de donnees
#
#  Entrees  : DATAS/data_eau/dis-*/DIS_{COM_UDI,PLV,RESULT}_*.txt  (10 millesimes)
#             DATAS/data_pesticides/consolidated_ift.csv
#  Sorties  : LIVRABLES/PHASE2/dictionnaire_donnees.csv
#             LIVRABLES/PHASE2/dictionnaire_donnees.tex
#             LIVRABLES/PHASE2/problemes_qualite.tex
#
#  Prerequis : install.packages(c("duckdb", "DBI", "data.table"))
#  Duree observee : ~13 min (dont 12 min sur les 20 Go de DIS_RESULT)
#
#  Principe : toutes les colonnes sont lues en VARCHAR (all_varchar = true).
#  On profile la donnee BRUTE, pas l'interpretation qu'en fait le parseur :
#  c'est la seule facon de voir les zeros de tete, les sentinelles et les
#  formats corrompus (cf. PQ-05, PQ-06, PQ-14).
# ==============================================================================

suppressMessages({library(DBI); library(duckdb); library(data.table)})

ROOT <- "U:/WaterQuality"
OUT  <- file.path(ROOT, "LIVRABLES", "PHASE2")
SRC  <- list(
  DIS_COM_UDI = file.path(ROOT, "DATAS/data_eau/dis-*/DIS_COM_UDI_*.txt"),
  DIS_PLV     = file.path(ROOT, "DATAS/data_eau/dis-*/DIS_PLV_*.txt"),
  DIS_RESULT  = file.path(ROOT, "DATAS/data_eau/dis-*/DIS_RESULT_*.txt"),
  IFT_SOLAGRO = file.path(ROOT, "DATAS/data_pesticides/consolidated_ift.csv")
)
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

con <- dbConnect(duckdb::duckdb(), dbdir = ":memory:")
dbExecute(con, "SET threads = 6")
dbExecute(con, "SET memory_limit = '8GB'")
dbExecute(con, "SET preserve_insertion_order = false")

reader <- function(glob) {
  sprintf("read_csv('%s', all_varchar = true, header = true, union_by_name = true)", glob)
}

# ------------------------------------------------------------------ #
# 1. Profil colonne par colonne, en une seule passe par fichier       #
# ------------------------------------------------------------------ #
# approx = TRUE : approx_count_distinct sur DIS_RESULT (125 M lignes),
# ou un COUNT(DISTINCT) exact ferait exploser la memoire.
profil <- function(con, glob, tbl, approx = FALSE) {
  src  <- reader(glob)
  cols <- names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", src)))
  parts <- vapply(cols, function(c) {
    q  <- sprintf('"%s"', c)
    nd <- if (approx) sprintf("approx_count_distinct(%s)", q) else sprintf("count(DISTINCT %s)", q)
    sprintf(paste0('count(*) FILTER (WHERE %s IS NULL OR trim(%s) = \'\') AS "mq__%s", ',
                   '%s AS "nd__%s", ',
                   'min(length(%s)) AS "lmin__%s", max(length(%s)) AS "lmax__%s", ',
                   'min(%s) AS "vmin__%s", max(%s) AS "vmax__%s"'),
            q, q, c, nd, c, q, c, q, c, q, c, q, c)
  }, character(1))

  res <- as.data.table(dbGetQuery(
    con, sprintf("SELECT count(*) AS n_lignes, %s FROM %s", paste(parts, collapse = ", "), src)))

  out <- rbindlist(lapply(cols, function(c) data.table(
    table = tbl, colonne = c, n_lignes = res$n_lignes[1],
    n_manquant = as.numeric(res[[paste0("mq__",   c)]]),
    n_distinct = as.numeric(res[[paste0("nd__",   c)]]),
    long_min   = as.numeric(res[[paste0("lmin__", c)]]),
    long_max   = as.numeric(res[[paste0("lmax__", c)]]),
    val_min    = as.character(res[[paste0("vmin__", c)]]),
    val_max    = as.character(res[[paste0("vmax__", c)]]))))

  out[, `:=`(pct_manquant = round(100 * n_manquant / n_lignes, 2),
             distinct_approx = approx, ordre = seq_len(.N))][]
}

message("[1/3] Profilage des colonnes...")
prof <- rbindlist(list(
  profil(con, SRC$DIS_COM_UDI, "DIS_COM_UDI"),
  profil(con, SRC$DIS_PLV,     "DIS_PLV"),
  profil(con, SRC$DIS_RESULT,  "DIS_RESULT", approx = TRUE),
  profil(con, SRC$IFT_SOLAGRO, "IFT_SOLAGRO")
))

# ------------------------------------------------------------------ #
# 2. Controles de qualite quantifies (registre PQ-01 a PQ-29)         #
# ------------------------------------------------------------------ #
message("[2/3] Controles de qualite...")
P <- reader(SRC$DIS_PLV); R <- reader(SRC$DIS_RESULT)
C <- reader(SRC$DIS_COM_UDI); I <- reader(SRC$IFT_SOLAGRO)

ctl <- list(
  # PQ-01 : le grain de DIS_PLV n'est pas le prelevement
  PQ01 = sprintf("SELECT count(*) lignes, count(DISTINCT referenceprel) prelevements,
                         round(100.0*count(*)/count(DISTINCT referenceprel)-100, 1) pct_inflation FROM %s", P),
  # PQ-01 bis : le dedoublonnage est-il sans perte ?
  PQ01b = sprintf("SELECT
      (SELECT count(*) FROM (SELECT referenceprel FROM %s GROUP BY 1 HAVING count(DISTINCT inseecommuneprinc)>1)) communes_divergentes,
      (SELECT count(*) FROM (SELECT referenceprel FROM %s GROUP BY 1 HAVING count(DISTINCT plvconformitechimique)>1)) conformites_divergentes", P, P),
  # PQ-02 : integrite referentielle du reseau amont
  PQ02 = sprintf("SELECT count(*) lignes_orphelines, count(DISTINCT cdreseauamont) codes_orphelins
                  FROM %s p WHERE cdreseauamont IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM %s c WHERE c.cdreseau = p.cdreseauamont)", P, C),
  # PQ-11 : modalites reelles des indicateurs de conformite
  PQ11 = sprintf("SELECT plvconformitechimique code, count(*) n FROM %s GROUP BY 1 ORDER BY n DESC", P),
  # PQ-13 / PQ-15 / PQ-16 : censure, qualitatifs, formats de seuils
  PQ16 = sprintf("SELECT count(*) n,
      count(*) FILTER (WHERE rqana LIKE '<%%') censure_gauche,
      count(*) FILTER (WHERE rqana LIKE '>%%') censure_droite,
      count(*) FILTER (WHERE rqana LIKE '<%%' AND TRY_CAST(replace(valtraduite,',','.') AS DOUBLE) = 0) censure_codee_zero,
      count(*) FILTER (WHERE qualitparam = 'O') qualitatifs,
      count(*) FILTER (WHERE limitequal LIKE '%%,%%' OR refqual LIKE '%%,%%') seuils_virgule,
      count(*) FILTER (WHERE limitequal LIKE '%%.%%' OR refqual LIKE '%%.%%') seuils_point,
      count(*) FILTER (WHERE limitequal LIKE '%%et%%' OR refqual LIKE '%%et%%') seuils_intervalle
      FROM %s", R),
  # PQ-25 : bornes logiques des indicateurs Solagro
  PQ25 = sprintf("SELECT max(TRY_CAST(p_sau AS DOUBLE)) p_sau_max,
      count(*) FILTER (WHERE TRY_CAST(p_sau AS DOUBLE) > 100) p_sau_sup100,
      max(TRY_CAST(p_bio AS DOUBLE)) p_bio_max,
      count(*) FILTER (WHERE TRY_CAST(p_bio AS DOUBLE) > 100) p_bio_sup100,
      count(*) FILTER (WHERE TRY_CAST(ift_t AS DOUBLE) > 20) ift_outliers FROM %s", I),
  # PQ-26 : communes hors territoire national
  PQ26 = sprintf("SELECT inseecommuneprinc, nomcommuneprinc, count(*) n FROM %s
                  WHERE inseecommuneprinc LIKE '99%%' GROUP BY 1,2 ORDER BY n DESC", P),
  # PQ-27 : perimetre geographique compare
  PQ27 = sprintf("SELECT (SELECT count(DISTINCT cddept) FROM %s) dept_sise,
                         (SELECT count(DISTINCT insee_dep) FROM %s) dept_solagro", P, I),
  # PQ-29 : prelevements sans resultat
  PQ29 = sprintf("SELECT (SELECT count(DISTINCT referenceprel) FROM %s) prel_plv,
                         (SELECT count(DISTINCT referenceprel) FROM %s) prel_result", P, R)
)
controles <- lapply(ctl, function(q) as.data.table(dbGetQuery(con, q)))
dbDisconnect(con, shutdown = TRUE)

# ------------------------------------------------------------------ #
# 3. Generation du dictionnaire (CSV + LaTeX)                         #
# ------------------------------------------------------------------ #
message("[3/3] Generation des livrables...")
annot <- fread(file.path(OUT, "annotations_colonnes.csv"), sep = "|", quote = "", encoding = "UTF-8")
d <- merge(prof, annot, by = c("table", "colonne"), all.x = TRUE, sort = FALSE)
setorder(d, table, ordre)

fmt <- function(x) formatC(x, format = "d", big.mark = " ")
fwrite(d[, .(Table = table, Colonne = colonne, Libelle = libelle,
             Type_source = "VARCHAR (fichier plat)", Type_cible_DW = type_cible, Role_DW = role_dw,
             Nb_lignes = fmt(n_lignes), Pct_manquant = sprintf("%.2f %%", pct_manquant),
             Nb_valeurs_distinctes = fifelse(distinct_approx, paste0("~", fmt(n_distinct)), fmt(n_distinct)),
             Longueur_min = long_min, Longueur_max = long_max,
             Valeur_min = val_min, Valeur_max = val_max,
             Regle_transformation = regle_transformation,
             Probleme_qualite = fifelse(is.na(pq) | pq == "", "-", pq))],
       file.path(OUT, "dictionnaire_donnees.csv"), sep = ";", bom = TRUE)

esc <- function(x) {
  x <- as.character(x); x[is.na(x)] <- ""
  x <- gsub("\\\\", "\\\\textbackslash{}", x)
  for (ch in c("&", "%", "$", "#", "_", "{", "}")) x <- gsub(ch, paste0("\\", ch), x, fixed = TRUE)
  gsub("~", "\\textasciitilde{}", x, fixed = TRUE)
}
lab <- c(DIS_COM_UDI = "SISE-Eaux --- DIS\\_COM\\_UDI (liaison commune / UDI)",
         DIS_PLV     = "SISE-Eaux --- DIS\\_PLV (prelevements)",
         DIS_RESULT  = "SISE-Eaux --- DIS\\_RESULT (resultats d'analyse)",
         IFT_SOLAGRO = "Solagro --- consolidated\\_ift (pression phytosanitaire)")

L <- c("% Genere par LIVRABLES/PHASE2/profilage_duckdb.R --- ne pas editer a la main",
       "\\section{Dictionnaire de donnees}", "")
for (tb in names(lab)) {
  s <- d[table == tb]
  L <- c(L, sprintf("\\subsection{%s}", lab[[tb]]),
         sprintf("\\noindent\\textit{Volumetrie mesuree : %s lignes, %d colonnes.}\\par\\smallskip",
                 fmt(s$n_lignes[1]), nrow(s)), "",
         "{\\footnotesize\\setlength{\\tabcolsep}{3pt}",
         "\\begin{longtable}{@{}p{2.6cm}p{3.5cm}p{1.9cm}p{3.1cm}p{1.1cm}p{1.3cm}p{0.9cm}@{}}",
         "\\toprule",
         "\\textbf{Colonne} & \\textbf{Libelle} & \\textbf{Type cible} & \\textbf{Role dans le DW} & \\textbf{\\% manq.} & \\textbf{Distinct} & \\textbf{PQ} \\\\",
         "\\midrule \\endfirsthead",
         "\\toprule \\textbf{Colonne} & \\textbf{Libelle} & \\textbf{Type cible} & \\textbf{Role dans le DW} & \\textbf{\\% manq.} & \\textbf{Distinct} & \\textbf{PQ} \\\\ \\midrule \\endhead",
         "\\bottomrule \\endfoot")
  for (i in seq_len(nrow(s))) {
    r <- s[i]
    L <- c(L, sprintf("\\texttt{%s} & %s & \\texttt{%s} & %s & %.2f & %s & %s \\\\",
                      esc(r$colonne), esc(r$libelle), esc(r$type_cible), esc(r$role_dw),
                      r$pct_manquant,
                      paste0(ifelse(r$distinct_approx, "$\\sim$", ""), fmt(r$n_distinct)),
                      ifelse(is.na(r$pq) | r$pq == "", "---", esc(r$pq))))
  }
  L <- c(L, "\\end{longtable}}", "")
}
writeLines(L, file.path(OUT, "dictionnaire_donnees.tex"), useBytes = TRUE)

# Registre qualite -> LaTeX
pq <- fread(file.path(OUT, "problemes_qualite.csv"), sep = ";", encoding = "UTF-8")
K <- c("% Genere par LIVRABLES/PHASE2/profilage_duckdb.R", "\\section{Registre des problemes de qualite}", "",
       "{\\footnotesize\\setlength{\\tabcolsep}{3pt}",
       "\\begin{longtable}{@{}p{1.1cm}p{2.2cm}p{4.2cm}p{3.6cm}p{4.3cm}@{}}", "\\toprule",
       "\\textbf{Id} & \\textbf{Categorie} & \\textbf{Probleme} & \\textbf{Quantification} & \\textbf{Action corrective} \\\\",
       "\\midrule \\endfirsthead",
       "\\toprule \\textbf{Id} & \\textbf{Categorie} & \\textbf{Probleme} & \\textbf{Quantification} & \\textbf{Action corrective} \\\\ \\midrule \\endhead",
       "\\bottomrule \\endfoot")
for (i in seq_len(nrow(pq))) {
  r <- pq[i]
  K <- c(K, sprintf("\\textbf{%s} & %s & %s & %s & %s \\\\[2pt]", esc(r$Id), esc(r$Categorie),
                    esc(r$Intitule), esc(r$Quantification_mesuree), esc(r$Action_corrective)))
}
writeLines(c(K, "\\end{longtable}}", ""), file.path(OUT, "problemes_qualite.tex"), useBytes = TRUE)

message("Termine. Controles cles :")
print(controles$PQ01); print(controles$PQ16)
