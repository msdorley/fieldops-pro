# Pilote FieldOps Pro

**Boîte à outils Windows portable pour l'intervention sur poste**

Version du produit : voir `CONFIG/version.json` · Licence : Apache 2.0
Document jumeau en anglais : `DOCS/PILOT-EN.md`

---

## 1. Ce que c'est

FieldOps Pro s'exécute depuis une clé USB et met seize outils à disposition du
technicien devant une machine : diagnostic matériel et disque, réparation
réseau, posture de sécurité, déploiement logiciel, inscription à l'annuaire,
configuration VPN, rapport de parc, rapport d'incident, procédures de
remédiation, auto-réparation guidée, comparaison de configuration, et évaluation
de conformité ANSSI.

**Rien n'est installé sur la machine examinée.** Tout fonctionne hors ligne.

### Ce qui le distingue

Les outils de terrain répondent *réussi* ou *échoué*. Quand une sonde ne peut
pas s'exécuter, que le matériel est absent ou que la réponse demande un
jugement humain, ils tranchent quand même et passent à la suite.

FieldOps Pro dispose d'un troisième verdict, et c'est la raison de l'utiliser.

| Verdict | Signification |
|---------|---------------|
| **Vérifié** | Le contrôle a été observé directement. |
| **Indéterminé** | La preuve est incomplète : sonde indisponible, matériel absent, ou jugement humain nécessaire. |
| **Hors périmètre** | Ne relève pas de ce qu'un examen de poste peut établir. |

Une machine dépourvue de TPM ne peut pas démontrer une authentification adossée
au matériel. L'annoncer conforme est faux ; l'annoncer non conforme laisse
entendre un défaut qui n'existe pas.

### Où en est cette discipline aujourd'hui

Soyons précis, parce que c'est exactement ce qu'un pilote doit vérifier.

Le module de conformité l'applique intégralement, sur les 42 règles. **Les autres
moteurs ne l'appliquent pas encore** : ils détectent bien ce qu'ils n'ont pas pu
établir, puis l'écartent avant l'affichage. Les reprendre sous le même contrat
est le chantier suivant, en commençant par le moteur de sécurité.

Autrement dit : la promesse est tenue sur une partie du produit, et votre retour
détermine dans quel ordre elle s'étend au reste.

---

## 2. Ce que le pilote vous demande

- **Vingt postes au minimum**, sur vos interventions réelles. En dessous, la
  diversité de configurations est trop faible pour rien apprendre.
- **Utiliser les outils qui vous servent**, pas ceux que nous mettons en avant.
  Si vous n'ouvrez jamais le module de conformité, c'est un résultat, pas un
  échec du pilote.
- **Si la conformité vous concerne : montrer au moins un rapport à un client.**
  C'est la seule chose que nos tests ne peuvent pas établir — un rapport qui
  satisfait son auteur et un rapport qui résiste au regard d'un client sont deux
  objets différents.
- **Un retour écrit sous six semaines.** Le questionnaire figure en section 6.
  Une page suffit.

Aucune exclusivité, aucun engagement de suite, aucune communication publique.
Vous pouvez interrompre le pilote sans motif.

---

## 3. Ce que vous obtenez

- **Le pilote est gratuit.** Ce n'est pas une version d'évaluation bridée : le
  produit est publié sous licence Apache 2.0 et vous l'auriez de toute façon. Ce
  que le pilote ajoute, c'est l'accès direct à l'auteur.
- **Un support nommé**, par courriel, sous 48 heures ouvrées.
- **Les correctifs pendant la durée du pilote**, prioritaires sur le reste de la
  feuille de route.
- **Vos remarques inscrites au changelog**, si vous le souhaitez et sous la forme
  que vous choisissez, y compris de façon anonyme.

---

## 4. Protocole

1. **Extraire** l'archive sur une clé USB. Aucune installation.
2. **Lancer** `FieldOps-Launcher.ps1`, puis exécuter l'auto-test. Il doit
   afficher **PRÊT**. S'il signale des réserves, envoyez-nous sa sortie avant
   d'aller plus loin — c'est déjà un résultat de pilote.
3. **Emporter la clé sur vos interventions** pendant six semaines et vous en
   servir là où elle vous rend service. Nous n'imposons pas d'ordre : ce que
   vous ouvrez spontanément nous en apprend davantage qu'un parcours guidé.
4. **Si la conformité vous concerne** : collecter avec SecurityScan, PCHealth et
   NetRepair, produire le rapport ANSSI, renseigner la page d'attestation
   (douze champs, les seuls modifiables du document), et le remettre à un client
   dans vos conditions habituelles.

Comptez une dizaine de minutes par poste pour la chaîne de conformité complète,
dont l'essentiel en collecte automatique. Les autres outils s'utilisent seuls,
au coup par coup.

### Confidentialité des données

Les diagnostics et les rapports sont **entièrement locaux**. Aucune donnée ne
quitte la machine examinée.

L'outil comporte par ailleurs des fonctions d'analyse assistée par IA, qui
transmettent un résumé de configuration à un fournisseur externe. **Elles ne
s'activent que si vous configurez vous-même une clé d'API** : sans clé, elles ne
s'exécutent pas. Pour un pilote, nous vous recommandons de ne pas en configurer.

---

## 5. Ce que le produit n'établit pas

Cette section est aussi importante que les précédentes. Un pilote qui découvre
ces limites en séance chez un client est un pilote raté.

- **Le troisième verdict ne couvre pas encore tout le produit.** Il est complet
  dans le module de conformité et absent des autres moteurs, qui affichent
  encore un résultat binaire. C'est la limite principale, et elle est en cours
  de traitement.
- **Le rapport de conformité n'est ni une certification ni une qualification
  ANSSI.** L'ANSSI est seule habilitée à en délivrer. Le document le dit sur sa
  couverture et dans sa conclusion.
- **Le projet n'a aucune affiliation avec l'ANSSI**, ni agrément, ni partenariat,
  ni approbation. Le *Guide d'hygiène informatique* est un document public ; nous
  nous y référons, rien de plus. Le reste de la boîte à outils ne dépend d'aucun
  référentiel ni d'aucun pays.
- **Seize règles sur quarante-deux sont hors périmètre par construction** :
  formation, procédures RH, architecture réseau, gouvernance. Aucun outil
  s'exécutant sur un poste isolé ne peut les attester.
- **Un rapport décrit une machine, à un instant.** Toute modification ultérieure
  de configuration invalide le constat. Le rapport horodate chacune de ses
  sources et signale toute collecte de plus de trente jours.
- **La console reste très majoritairement en français.** Le rapport de
  conformité, lui, est intégralement bilingue et vérifié comme tel par les tests.

---

## 6. Le retour attendu

Six questions. Répondez brièvement ; les réponses courtes et franches valent
mieux qu'un rapport d'évaluation.

1. **Quels outils avez-vous réellement utilisés, et lesquels n'avez-vous jamais
   ouverts ?**
   *La question qui compte. Un outil que personne n'ouvre n'existe pas.*
2. Y a-t-il eu un moment où l'outil vous a dit qu'il ne pouvait pas conclure ?
   Cela vous a-t-il aidé, ou agacé ?
3. Qu'avez-vous dû faire avec un autre outil parce que celui-ci ne le faisait
   pas, ou le faisait mal ?
4. Si vous avez remis un rapport de conformité à un client : qu'a-t-il dit ?
5. Sur vingt interventions, combien de fois auriez-vous repris la clé si elle
   n'avait pas été fournie ?
6. Le feriez-vous payer ? À quel prix, pour quelle partie, et à quel client ?

Format libre : courriel, document, ou appel de vingt minutes si vous préférez.

---

## 7. Contact et suites

Ousman Dorley — <170084095+msdorley@users.noreply.github.com>

Anomalies et demandes : dépôt public du projet, ou courriel direct pendant le
pilote.

Les conditions d'un usage commercial ultérieur sont ouvertes et documentées dans
`COMMERCIAL-LICENSING.md`. Elles ne conditionnent pas ce pilote et n'ont pas à
être discutées pour y participer.
