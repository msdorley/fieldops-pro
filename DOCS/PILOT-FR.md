# Pilote FieldOps Pro

**Diagnostic d'hygiène informatique — référentiel ANSSI, 42 règles**

Version du produit : voir `CONFIG/version.json` · Licence : Apache 2.0
Document jumeau en anglais : `DOCS/PILOT-EN.md`

---

## 1. Ce que c'est

FieldOps Pro est un outil de diagnostic portable qui évalue un poste Windows au
regard des 42 règles du *Guide d'hygiène informatique* de l'ANSSI, puis produit
un rapport A4 paginé, signable, destiné à être remis à un client.

Il s'exécute depuis une clé USB. **Rien n'est installé sur la machine examinée.**

Ce qui le distingue tient en une seule décision : le rapport comporte **trois**
verdicts, non pas deux.

| Verdict | Signification |
|---------|---------------|
| **Conforme vérifié** | Le contrôle a été observé en place. |
| **Partiellement vérifié** | La preuve est incomplète : sonde indisponible, matériel absent, ou jugement humain nécessaire. |
| **Hors périmètre** | La règle ne relève pas de ce qu'un audit de poste peut établir. |

Une machine dépourvue de TPM ne peut pas démontrer une authentification adossée
au matériel. L'annoncer conforme est faux ; l'annoncer non conforme laisse
entendre un défaut qui n'existe pas. Un auditeur a besoin de savoir **quelles
règles ont réellement été vérifiées** — c'est précisément ce que la plupart des
tableaux de bord de conformité effacent en n'affichant que du vert et du rouge.

C'est là tout le produit. Le reste n'en est que le support.

---

## 2. Ce que le pilote vous demande

- **Vingt postes au minimum.** En dessous, la diversité de configurations est
  trop faible pour que les résultats vous apprennent quoi que ce soit.
- **Montrer au moins un rapport à un client réel.** C'est la seule chose que nos
  tests ne peuvent pas établir : un rapport qui satisfait son auteur et un
  rapport qui résiste au regard d'un client sont deux objets différents.
- **Un retour écrit sous six semaines.** Le questionnaire figure en section 6.
  Une page suffit.

Aucune exclusivité n'est demandée, aucun engagement de suite, aucune
communication publique. Vous pouvez interrompre le pilote sans motif.

---

## 3. Ce que vous obtenez

- **Le pilote est gratuit.** Il n'est pas une version d'évaluation bridée : le
  produit est publié sous licence Apache 2.0 et vous l'auriez de toute façon.
  Ce que le pilote ajoute, c'est l'accès direct à l'auteur.
- **Un support nommé**, par courriel, sous 48 heures ouvrées.
- **Les correctifs pendant la durée du pilote**, prioritaires sur le reste de la
  feuille de route.
- **Vos remarques inscrites au changelog**, si vous le souhaitez et sous la forme
  que vous choisissez, y compris de façon anonyme.

---

## 4. Protocole

1. **Extraire** l'archive de la version sur une clé USB. Aucune installation.
2. **Lancer** `FieldOps-Launcher.ps1`, puis exécuter l'auto-test. Il doit
   afficher **PRÊT**. S'il signale des réserves, envoyez-nous sa sortie avant
   d'aller plus loin — c'est déjà un résultat de pilote.
3. **Collecter** sur chaque poste : SecurityScan, PCHealth, NetRepair.
4. **Produire** le rapport de diagnostic ANSSI. Le rapport s'ouvre en HTML et se
   convertit en PDF.
5. **Renseigner** la page d'attestation : votre nom, votre société, le lieu et la
   date. Douze champs, les seuls modifiables du document.
6. **Remettre** un rapport à un client, dans les conditions où vous le feriez
   normalement.

Comptez environ dix minutes par poste, dont l'essentiel en collecte automatique.

### Confidentialité des données

Le diagnostic et le rapport sont **entièrement locaux**. Aucune donnée ne quitte
la machine examinée.

L'outil comporte par ailleurs des fonctions d'analyse assistée par IA, qui
transmettent un résumé de configuration à un fournisseur externe. **Elles ne
s'activent que si vous configurez vous-même une clé d'API** : sans clé, elles ne
s'exécutent pas. Pour un pilote, nous vous recommandons de ne pas en configurer.

---

## 5. Ce que le rapport n'établit pas

Cette section est aussi importante que les précédentes. Un pilote qui découvre
ces limites en séance chez un client est un pilote raté.

- **Ce n'est ni une certification ni une qualification ANSSI.** L'ANSSI est seule
  habilitée à en délivrer. Le document le dit sur sa couverture et dans sa
  conclusion.
- **Le projet n'a aucune affiliation avec l'ANSSI**, ni agrément, ni partenariat,
  ni approbation. Le *Guide d'hygiène informatique* est un document public ; nous
  nous y référons, rien de plus.
- **Seize règles sur quarante-deux sont hors périmètre par construction** :
  formation, procédures RH, architecture réseau, gouvernance. Aucun outil
  s'exécutant sur un poste isolé ne peut les attester. Elles figurent au rapport
  pour que le référentiel reste complet, en annexe et sans verdict.
- **Le rapport décrit une machine, à un instant.** Toute modification ultérieure
  de configuration invalide le constat. Le rapport horodate chacune de ses
  sources et signale toute collecte de plus de trente jours.
- **La console de l'outil reste très majoritairement en français.** Le rapport,
  lui, est intégralement bilingue et vérifié comme tel par les tests.

---

## 6. Le retour attendu

Six questions. Répondez brièvement ; les réponses courtes et franches valent
mieux qu'un rapport d'évaluation.

1. **L'avez-vous montré à un client ? Qu'a-t-il dit ?**
   *La question qui compte. Les cinq autres sont secondaires.*
2. Le verdict « partiellement vérifié » a-t-il été compris, ou a-t-il fallu
   l'expliquer ? Si oui, comment l'avez-vous formulé ?
3. Qu'avez-vous cherché dans le rapport sans le trouver ?
4. Qu'y avez-vous trouvé d'inutile, ou de faux ?
5. Sur vingt postes, combien de rapports auriez-vous remis tels quels, sans
   retouche ?
6. Le feriez-vous payer ? À quel prix, et à quel client ?

Format libre : courriel, document, ou appel de vingt minutes si vous préférez.

---

## 7. Contact et suites

Ousman Dorley — <170084095+msdorley@users.noreply.github.com>

Anomalies et demandes : dépôt public du projet, ou courriel direct pendant le
pilote.

Les conditions d'un usage commercial ultérieur sont ouvertes et documentées dans
`COMMERCIAL-LICENSING.md`. Elles ne conditionnent pas ce pilote et n'ont pas à
être discutées pour y participer.
