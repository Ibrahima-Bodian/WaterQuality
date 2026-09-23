# Phase 2 — Modeling : cadrage

> Rapport attendu le **vendredi 3/10 avant 18h** · Séance Q&A notée le **6/10**
> Livrables exigés : schémas conceptuels DFM · dictionnaire de données · workload formalisé (langage abstrait de Golfarelli & Rizzi) · maquettes de rapports · annexe gestion de projet

## 1. Recadrage par rapport à la Phase 1

La critique des encadrants porte sur un point unique : la Phase 1 décrit un **projet d'analyse de données**, alors que l'évaluation porte sur un **projet d'entrepôt de données**. Les phases Modeling + Loading pèsent 60 % de la note du semestre.

Les 8 besoins utilisateurs sont conservés. Ce qui change, c'est leur expression : chaque besoin doit devenir une **navigation OLAP** (plusieurs dimensions, plusieurs mesures, réponse exploratoire) et non une question à réponse unique.

## 2. Décisions techniques verrouillées

| Sujet | Décision | Justification |
|---|---|---|
| Profondeur temporelle | **2016 → 2025** (10 millésimes) | Schémas sources strictement identiques sur les 10 années : l'union est triviale. 125 M analyses, 2,83 M prélèvements. |
| Stockage / requêtage | **DuckDB** | Lit les 20 Go de CSV sans serveur ni chargement préalable. Le profilage complet tourne en ~13 min (mesuré). Se branche sur R et sur les outils de restitution. |
| ETL | **KNIME** | Workflows « code-free » exigés en Phase 3. Permet le travail à 4. |
| Statistiques et ML | **R** | Déjà installé (4.6.1, `data.table`, `arrow`, `duckdb`). *Python n'est pas installé sur le poste.* |
| Restitution | Tableau / Power BI | Inchangé. |

> Excel et Power Query sont abandonnés : `DIS_RESULT` fait 12,6 M lignes **par an**, très au-delà de la limite d'une feuille de calcul.

## 3. Troisième source de données

La consigne impose ≥ 2 sources, et en recommande 3 pour les groupes FI. Source retenue :

**Achats de pesticides par code postal (BNV-D)** — <https://www.data.gouv.fr/datasets/achats-de-pesticides-par-code-postal-1>

Pourquoi celle-ci :

- Elle est **citée dans le sujet** : aucun risque de hors-sujet.
- Elle apporte un **vrai problème d'intégration**, qui est exactement ce que la consigne demande d'illustrer : la source est au **code postal**, alors que les deux autres sont au **code INSEE**. La relation code postal ↔ commune est **N-N** — un second arc multiple, distinct de celui du réseau amont.
- Elle mesure les **achats**, là où Solagro mesure l'**usage** : la confrontation des deux est en soi un résultat analysable.
- Elle couvre une période plus longue que Solagro (limité à 2020–2022), ce qui sert la profondeur 2016–2025 retenue.

Elle alimente un **3ᵉ fait `ACHAT_PHYTO`** (grain : code postal × année × substance), relié à `DIM_TEMPS`, `DIM_GEOGRAPHIE` et `DIM_SUBSTANCE`. La dimension substance se raccorde à `DIM_PARAMETRE` de SISE-Eaux par le **numéro CAS** (présent sur 58 % des lignes de `DIS_RESULT`, 1 227 valeurs distinctes) — c'est le point de jointure qui permet de suivre une substance depuis son achat jusqu'à son résidu au robinet.

*Option, si le groupe veut une 4ᵉ source :* pesticides dans les eaux souterraines (≈ 2 200 stations géolocalisées, 600 substances) — ajoute le maillon nappe phréatique entre l'agriculture et le robinet.

> ⚠️ Cette source n'est pas encore dans `DATAS/`. Son schéma réel doit être profilé avec `profilage_duckdb.R` avant d'être figé dans le dictionnaire.

## 4. Besoins ML — répartition sur les 4 membres

La contrainte est de **1 besoin ML par étudiant en FA, 2 en FI**, avec au moins un supervisé et un non supervisé. La Phase 1 n'en comptait que 2, tous deux portés par un seul membre. Répartition corrigée — chacun porte **un supervisé et un non supervisé** :

| Membre | Axe | Besoin ML supervisé | Besoin ML non supervisé |
|---|---|---|---|
| **Sham** | Cartographie | **ML-2** Classification multi-classes de la conclusion sanitaire à partir du profil de paramètres analysés | **ML-1** Règles d'association entre paramètres dépassés sur un même prélèvement (FP-Growth) → profils de contamination |
| **Ibrahima** | Corrélation agricole | **ML-3** Régression (forêt aléatoire / gradient boosting) du taux de non-conformité communal sur les indicateurs Solagro, avec importance des variables | **ML-4** ACP sur les indicateurs de pression (`ift_*`, `p_sau`, `p_bio`, `p_bc`) → indice synthétique de pression agricole |
| **Fatoumata** | Évolution temporelle | **ML-5** Prévision de série temporelle du taux de non-conformité par département — apprentissage 2016-2024, **test réel sur 2025** | **ML-6** Détection d'anomalies et de ruptures sur les séries par réseau (Isolation Forest / détection de changement) |
| **Fanta** | Zones à risque | **ML-8** Prédiction du statut « commune à risque » : régression logistique **comparée** à un modèle d'ensemble, évaluation ROC/AUC en validation croisée | **ML-7** Clustering K-means des communes en profils de risque (méthode du coude, caractérisation des groupes) |

Les groupes FA ne retiennent qu'un besoin par membre ; les autres restent décrits dans le rapport, comme la consigne l'autorise.

Les tests statistiques de la Phase 1 (Spearman, Mann-Whitney, Shapiro-Wilk, Pareto) sont conservés — mais comme **étape de data analyse**, pas comme besoins ML : ce ne sont pas des méthodes de fouille de données au sens de la consigne.

## 5. Conformité aux contraintes

| Contrainte | Exigence | État |
|---|---|---|
| Besoins requêtes | ≥ 2 / étudiant = 8 | ✅ 8 |
| Besoins ML | 4 (FA) ou 8 (FI) | ✅ 8, dont 4 supervisés et 4 non supervisés |
| Sources | ≥ 2, 3 pour FI | ✅ 3 (SISE-Eaux, Solagro, BNV-D) |
| Types de correction qualité | ≥ 2, 4 recommandés pour FI | ✅ **29 problèmes** quantifiés, 12 catégories (`problemes_qualite.csv`) |
| Volume | ≥ 500 faits pour le supervisé | ✅ 125 M analyses, 2,83 M prélèvements, 34 806 communes |

## 6. Contenu de ce dossier

| Fichier | Rôle |
|---|---|
| `profilage_duckdb.R` | Script reproductible : profile les 20 Go et régénère tous les livrables ci-dessous |
| `annotations_colonnes.csv` | Couche métier saisie à la main (libellé, type cible, rôle DW, règle de transformation) |
| `dictionnaire_donnees.csv` | **Dictionnaire de données** — 87 colonnes documentées, statistiques mesurées sur la totalité des fichiers |
| `dictionnaire_donnees.tex` | Même contenu en `longtable`, à inclure dans le rapport LaTeX |
| `problemes_qualite.csv` | Registre PQ-01 à PQ-29 : problème, quantification, impact, action corrective, étape ETL |
| `problemes_qualite.tex` | Même contenu en `longtable` |

Inclusion dans le rapport :

```latex
\usepackage{longtable}
...
\input{PHASE2/dictionnaire_donnees}
\input{PHASE2/problemes_qualite}
```

## 7. Reste à produire d'ici le 3/10

1. Schémas conceptuels **DFM** des faits `ANALYSE`, `PRELEVEMENT`, `PRESSION_AGRICOLE`, `ACHAT_PHYTO` (constellation à dimensions conformes `DIM_TEMPS` / `DIM_GEOGRAPHIE`).
2. **Workload formalisé** : les 8 besoins requêtes réécrits en besoins *fuzzy* puis traduits dans le langage abstrait de Golfarelli & Rizzi.
3. **Maquettes de rapports** illustrant chaque besoin.
4. Profilage de la 3ᵉ source une fois téléchargée, et extension du dictionnaire.
5. Annexe gestion de projet : répartition, Gantt, indicateurs d'avancement, coordinateur de phase.
