# SPDX-License-Identifier: Apache-2.0
<#
================================================================================
FrenchWordlist.ps1 -- FieldOps Pro Phase 7, Stream 7.1
================================================================================
The curated list of French security and compliance terms used to detect French
prose, shared by every check that needs it.

WHY THIS FILE EXISTS
    Two checks need the same list, for opposite purposes:

      - Find-HardcodedStringsInTemplate.ps1 (6.1-R4a) scans the TEMPLATE for
        French that should have been routed through the locale bundle.
      - EnglishRender.Locale.Tests.ps1 (7.1) scans a RENDERED ENGLISH REPORT
        for French that reached a reader.

    Holding one list in one file means a term added for one check protects the
    other. A copy in each would drift, and the drift would be silent.

WHY A WORDLIST AND NOT ACCENT DETECTION
    Accent detection answers a different question. The template is ASCII, so its
    French carries no diacritics and accent detection reports zero findings on a
    largely untranslated file. In the other direction, counting accents in a
    rendered report measures how good the FRENCH is and says nothing at all
    about whether the ENGLISH render is English -- which is precisely the
    mistake that let 7.1 look finished when only half of it was done.

    Dot-source this file; it defines a variable and does nothing else.
================================================================================
#>

Set-StrictMode -Version 1.0

$script:FrenchWords = @(
    'acces','affiliation','agrement','annexe','apporte','approbation','architecture'
    'attestable','attestation','attestees','audit','audite','autorite','automatiquement'
    'aucune','cartographie','certification','certifications','complementaire','conclusion'
    'conformite','constat','constitue','contextuelle','contractuelle','controle'
    'couverture','date','delivrer','diagnostic','document','donnees','elements'
    'employe','ensemble','etat','evaluation','exploitation','fabricant','formation'
    'generation','gouvernance','habilitee','hors','hygiene','informatique','instant'
    'invalident','invaliderait','isole','juridique','lecture','limitee','machines'
    'manuelle','materiel','mesures','methode','modele','modifications','module'
    'modules','necessitent','niveau','nom','numero','observation','observee','observes'
    'officielles','organisationnelle','organisationnelles','outil','partenariat'
    'partiellement','perimetre','poste','postes','posterieures','procedures','qualifications'
    'rapport','reference','referentiel','regle','regles','releve','relevent','reseau'
    'restantes','resultat','resultats','securite','separe','serie','seule','signature'
    'spectre','structure','supplementaires','synthese','systeme','technique','terme'
    'utilisateur','utilisateurs','verifie','verifier','vue'
)

# ---------------------------------------------------------------------------
# The French-only subset, for scanning an ENGLISH render.
# ---------------------------------------------------------------------------
# The list above cannot be used in that direction. Roughly a fifth of it is
# also ordinary English -- date, document, audit, module, modules, signature,
# structure, technique, reference, rapport, hygiene, instant, evaluation,
# formation, generation, exploitation, observation, machines, procedures,
# qualifications, elements, ensemble, lecture, modifications -- so it would
# flag a correct English report and the guard would be useless.
#
# These terms are French and are not words an English report should contain.
$script:FrenchOnlyWords = @(
    'acces','agrement','apporte','attestees','aucune','complementaire'
    'conformite','constat','contextuelle','contractuelle','controle','couverture'
    'delivrer','donnees','employe','etat','fabricant','gouvernance','habilitee'
    'hors','informatique','invalident','invaliderait','juridique','limitee'
    'manuelle','materiel','mesures','methode','modele','necessitent','niveau'
    'numero','observee','officielles','organisationnelle','organisationnelles'
    'outil','partenariat','partiellement','perimetre','postes','posterieures'
    'referentiel','regle','regles','releve','relevent','reseau','restantes'
    'resultat','resultats','securite','separe','serie','seule','spectre'
    'supplementaires','synthese','systeme','terme','utilisateur','utilisateurs'
    'verifie','verifier','vue'
)
