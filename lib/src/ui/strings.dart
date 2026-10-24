/// User-facing texts. English is the default; French is complete and uses
/// the formal "vous". `{name}` placeholders are filled by [Strings.call].
final class Strings {
  Strings._(this.locale, this._table);

  /// `en` or `fr`. Unknown locales fall back to English.
  factory Strings.of(String? locale) {
    final code = (locale ?? 'en').toLowerCase();
    return code.startsWith('fr') ? Strings._('fr', fr) : Strings._('en', en);
  }

  final String locale;
  final Map<String, String> _table;

  static const supported = ['en', 'fr'];

  bool has(String key) => _table.containsKey(key) || en.containsKey(key);

  String call(String key, [Map<String, Object?> args = const {}]) {
    final template = _table[key] ?? en[key] ?? key;
    return template.replaceAllMapped(
      RegExp(r'\{(\w+)\}'),
      (m) => args.containsKey(m.group(1)) ? '${args[m.group(1)]}' : m.group(0)!,
    );
  }

  /// Picks `<key>.one` or `<key>.other` according to [count].
  String plural(
    String key,
    int count, [
    Map<String, Object?> args = const {},
  ]) =>
      call(count == 1 ? '$key.one' : '$key.other', {'n': count, ...args});

  static const en = <String, String>{
    'tagline':
        'Rehearse your next Flutter upgrade in a sandbox. Apply only what is '
            'proven.',
    'welcome.title': 'Get started',
    'welcome.doctor': 'check your environment',
    'welcome.plan': 'simulate the upgrade in a sandbox',
    'welcome.report': 'open the verified plan',
    'welcome.apply': 'apply it, with a backup',
    'welcome.help': 'Run {command} to see every command and option.',
    'welcome.footer': 'Your project is never modified before `apply`.',
    'label.project': 'Project',
    'label.platforms': 'Platforms',
    'label.sandbox': 'Sandbox',
    'label.target': 'Target',
    'sandbox.note': 'isolated copy, your project stays untouched',
    'stage.inspect': 'Inspect project',
    'stage.resolve': 'Resolve Flutter {target}',
    'stage.resolved': 'Resolve Flutter {version} ({channel})',
    'stage.prepare': 'Prepare Flutter {version}',
    'stage.sandbox': 'Create sandbox',
    'stage.verify': 'Verify upgrade',
    'attempt.first': 'attempt {n}/{max}',
    'attempt.retry': 'retry {n}/{max}',
    'attempt.noChange': 'current toolchain',
    'detail.project': '{name}',
    'detail.releases.cache': 'cached release list',
    'detail.sdk.global': 'installed',
    'detail.sdk.fvm': 'from FVM',
    'detail.sdk.cache': 'cached',
    'detail.sdk.download': 'downloaded, checksum verified',
    'detail.files': '{files} files',
    'detail.filesSecrets': '{files} files, {secrets} secrets excluded',
    'detail.an earlier step failed': 'skipped (an earlier step failed)',
    'detail.time budget exhausted': 'time budget exhausted',
    'detail.timed out': 'timed out',
    'detail.interrupted': 'interrupted',
    'step.pub get': 'pub get',
    'step.analyze': 'analyze',
    'step.build apk': 'build apk',
    'step.build ios': 'build ios (no-codesign)',
    'step.test': 'tests',
    'step.skipped.platform not selected': 'skipped (platform not selected)',
    'step.skipped.requires macOS': 'skipped (requires macOS)',
    'step.skipped.Xcode not available': 'skipped (Xcode not available)',
    'step.skipped.Android SDK not found': 'skipped (Android SDK not found)',
    'step.skipped.not run (use --run-tests)': 'skipped (use --run-tests)',
    'step.skipped.the project has no android/ folder':
        'skipped (no android/ folder)',
    'step.skipped.the project has no ios/ folder': 'skipped (no ios/ folder)',
    'panel.verified': 'Verified plan',
    'panel.warnings': 'Verified plan, with warnings',
    'panel.blocked': 'Plan blocked',
    'panel.changes.one': '{n} change',
    'panel.changes.other': '{n} changes',
    'panel.deps.one': '{n} dependency to update',
    'panel.deps.other': '{n} dependencies to update',
    'panel.blocked.one': '{n} blocked',
    'panel.blocked.other': '{n} blocked',
    'panel.android': 'Android build',
    'panel.ios': 'iOS build',
    'panel.tests': 'Tests',
    'panel.notRun': 'not run',
    'section.changes': 'Changes',
    'section.changesTried': 'Changes tried',
    'section.changesTried.note': 'last attempt, not verified',
    'section.blocked': 'Blocked',
    'section.notVerified': 'Not verified',
    'section.manual': 'Manual steps',
    'section.next': 'Next',
    'section.diagnosis': 'Diagnosis',
    'blocked.suggestion': 'suggestion (not verified): {text}',
    'blocked.explain': 'details: upgrade-pilot explain {id}',
    'plan.duration': 'Done in {duration}.',
    'plan.cachedList': 'Release list from cache (offline): it may be outdated.',
    'plan.keptSandbox': 'Sandbox kept at {path}',
    'plan.noChanges':
        'Nothing to change: the project already builds with Flutter {version}.',
    'plan.saved': 'Plan saved. Re-render it with `upgrade-pilot report`.',
    'error.why': 'Why',
    'error.fix': 'What to do',
    'error.more': 'More info',
    'error.usage.title': 'Invalid command line',
    'error.usage.fix': 'Run `upgrade-pilot help` or add --help to a command.',
    'error.notFlutter.title': 'Not a Flutter project',
    'error.notFlutter.fix':
        'Run the command in a Flutter app folder, or pass --path <dir>.',
    'error.manifest.title': 'Unreadable project file',
    'error.manifest.fix':
        'Fix the file so that `flutter pub get` accepts it, then try again.',
    'error.release.title': 'Unknown Flutter version',
    'error.release.fix':
        'Use a released version (e.g. 3.44.9), a minor (3.44), `stable`, '
            '`beta` or `latest`.',
    'error.offline.title': 'Not available offline',
    'error.offline.fix':
        'Run the command once with network access, or drop --offline.',
    'error.network.title': 'Network error',
    'error.network.fix':
        'Check your connection or proxy, or use --offline with cached data.',
    'error.sdk.title': 'Flutter SDK unavailable',
    'error.sdk.fix':
        'Check `upgrade-pilot doctor`, free some space, then try again.',
    'error.disk.title': 'Not enough disk space',
    'error.disk.why': '{required} are needed, {available} are free.',
    'error.disk.fix':
        'Free some space or run `upgrade-pilot clean`, then try again.',
    'error.noPlan.title': 'No plan for this project',
    'error.noPlan.fix': 'Run `upgrade-pilot plan` first.',
    'error.blockedPlan.title': 'The last plan is blocked',
    'error.blockedPlan.why': 'Only a verified plan can be applied.',
    'error.blockedPlan.fix':
        'Resolve the blocking items, then run `upgrade-pilot plan` again.',
    'error.emptyPlan.title': 'Nothing to apply',
    'error.emptyPlan.why': 'The verified plan contains no file change.',
    'error.emptyPlan.fix': 'Follow the manual steps of the plan, if any.',
    'error.changed.title': 'The project changed since the plan',
    'error.changed.why':
        'Files covered by the plan were edited after `plan` ran.',
    'error.changed.fix':
        'Run `upgrade-pilot plan` again to verify the current state.',
    'error.dirty.title': 'Uncommitted changes',
    'error.dirty.why':
        'apply needs a clean git working tree to stay reversible.',
    'error.dirty.fix': 'Commit or stash your changes, or pass --force.',
    'error.conflict.title': 'File differs from the plan',
    'error.conflict.why':
        '{path} does not match the content recorded by the plan.',
    'error.conflict.fix': 'Run `upgrade-pilot plan` again.',
    'error.noBackup.title': 'No backup to restore',
    'error.noBackup.fix': 'Backups are created by `upgrade-pilot apply`.',
    'error.notConfirmed.title': 'Confirmation required',
    'error.notConfirmed.why': 'The terminal is not interactive.',
    'error.notConfirmed.fix': 'Pass --yes to apply without a prompt.',
    'error.unknownFinding.title': 'Unknown identifier {id}',
    'error.unknownFinding.fix':
        'Use an identifier from the last plan, e.g. UP-AND-0007.',
    'error.kb.title': 'Knowledge base rejected',
    'error.kb.fix':
        'Keep using the embedded knowledge base, and report the problem.',
    'error.interrupted.title': 'Interrupted',
    'error.interrupted.why': 'Ctrl+C received; the sandbox was removed.',
    'error.interrupted.fix': 'Run the command again when you are ready.',
    'error.internal.title': 'Unexpected error',
    'error.internal.fix': 'Run again with --verbose and report the issue.',
    'error.plan.title': 'Stored plan unreadable',
    'error.plan.fix': 'Run `upgrade-pilot plan` again.',
    'apply.confirm': 'Apply {changes} to {project}? [y/N] ',
    'apply.done': 'Applied {changes}.',
    'apply.backup': 'Backup: {path}',
    'apply.revertHint': 'Undo with `upgrade-pilot apply --revert`.',
    'apply.reverted': 'Restored {count} files from the backup.',
    'apply.cancelled': 'Nothing was changed.',
    'doctor.title': 'Environment',
    'doctor.ok': 'Ready to plan.',
    'doctor.missing': 'A required tool is missing.',
    'explain.cause': 'Cause',
    'explain.fix': 'Fix',
    'explain.evidence': 'Evidence',
    'explain.confidence': 'Confidence',
    'explain.source': 'Source',
    'explain.noEvidence':
        'Not seen in the last plan; general description of the rule.',
    'report.written': 'Report written to {path}',
    'kb.updated': 'Knowledge base updated: {from} → {to}.',
    'kb.current': 'Knowledge base already up to date ({version}).',
    'clean.done.one': 'Removed {n} item.',
    'clean.done.other': 'Removed {n} items.',
    'clean.nothing': 'Nothing to clean.',
    'confidence.high': 'high',
    'confidence.medium': 'medium',
    'confidence.low': 'low',
  };

  static const fr = <String, String>{
    'tagline':
        'Répétez votre prochaine mise à jour Flutter dans un bac à sable. '
            "N'appliquez que ce qui est prouvé.",
    'welcome.title': 'Pour commencer',
    'welcome.doctor': 'vérifier votre environnement',
    'welcome.plan': 'simuler la mise à jour dans un bac à sable',
    'welcome.report': 'ouvrir le plan vérifié',
    'welcome.apply': "l'appliquer, avec une sauvegarde",
    'welcome.help':
        'Lancez {command} pour voir toutes les commandes et options.',
    'welcome.footer': "Votre projet n'est jamais modifié avant `apply`.",
    'label.project': 'Projet',
    'label.platforms': 'Plateformes',
    'label.sandbox': 'Bac à sable',
    'label.target': 'Cible',
    'sandbox.note': 'copie isolée, votre projet reste intact',
    'stage.inspect': 'Analyser le projet',
    'stage.resolve': 'Résoudre Flutter {target}',
    'stage.resolved': 'Résoudre Flutter {version} ({channel})',
    'stage.prepare': 'Préparer Flutter {version}',
    'stage.sandbox': 'Créer le bac à sable',
    'stage.verify': 'Vérifier la mise à jour',
    'attempt.first': 'essai {n}/{max}',
    'attempt.retry': 'nouvel essai {n}/{max}',
    'attempt.noChange': 'chaîne d’outils actuelle',
    'detail.project': '{name}',
    'detail.releases.cache': 'liste des versions en cache',
    'detail.sdk.global': 'installé',
    'detail.sdk.fvm': 'via FVM',
    'detail.sdk.cache': 'en cache',
    'detail.sdk.download': 'téléchargé, somme de contrôle vérifiée',
    'detail.files': '{files} fichiers',
    'detail.filesSecrets': '{files} fichiers, {secrets} secrets exclus',
    'detail.an earlier step failed': 'ignoré (une étape précédente a échoué)',
    'detail.time budget exhausted': 'budget de temps épuisé',
    'detail.timed out': 'délai dépassé',
    'detail.interrupted': 'interrompu',
    'step.pub get': 'pub get',
    'step.analyze': 'analyze',
    'step.build apk': 'build apk',
    'step.build ios': 'build ios (sans signature)',
    'step.test': 'tests',
    'step.skipped.platform not selected': 'ignoré (plateforme non choisie)',
    'step.skipped.requires macOS': 'ignoré (macOS requis)',
    'step.skipped.Xcode not available': 'ignoré (Xcode indisponible)',
    'step.skipped.Android SDK not found': 'ignoré (SDK Android introuvable)',
    'step.skipped.not run (use --run-tests)': 'ignoré (utilisez --run-tests)',
    'step.skipped.the project has no android/ folder':
        'ignoré (pas de dossier android/)',
    'step.skipped.the project has no ios/ folder':
        'ignoré (pas de dossier ios/)',
    'panel.verified': 'Plan vérifié',
    'panel.warnings': 'Plan vérifié, avec avertissements',
    'panel.blocked': 'Plan bloqué',
    'panel.changes.one': '{n} modification',
    'panel.changes.other': '{n} modifications',
    'panel.deps.one': '{n} dépendance à mettre à jour',
    'panel.deps.other': '{n} dépendances à mettre à jour',
    'panel.blocked.one': '{n} bloquée',
    'panel.blocked.other': '{n} bloquées',
    'panel.android': 'Build Android',
    'panel.ios': 'Build iOS',
    'panel.tests': 'Tests',
    'panel.notRun': 'non lancés',
    'section.changes': 'Modifications',
    'section.changesTried': 'Modifications essayées',
    'section.changesTried.note': 'dernier essai, non vérifié',
    'section.blocked': 'Bloqué',
    'section.notVerified': 'Non vérifié',
    'section.manual': 'Étapes manuelles',
    'section.next': 'Ensuite',
    'section.diagnosis': 'Diagnostic',
    'blocked.suggestion': 'suggestion (non vérifiée) : {text}',
    'blocked.explain': 'détails : upgrade-pilot explain {id}',
    'plan.duration': 'Terminé en {duration}.',
    'plan.cachedList':
        'Liste des versions issue du cache (hors ligne) : elle peut être '
            'ancienne.',
    'plan.keptSandbox': 'Bac à sable conservé dans {path}',
    'plan.noChanges':
        'Rien à modifier : le projet compile déjà avec Flutter {version}.',
    'plan.saved': 'Plan enregistré. Réaffichez-le avec `upgrade-pilot report`.',
    'error.why': 'Pourquoi',
    'error.fix': 'Que faire',
    'error.more': "Plus d'infos",
    'error.usage.title': 'Ligne de commande invalide',
    'error.usage.fix':
        'Lancez `upgrade-pilot help` ou ajoutez --help à une commande.',
    'error.notFlutter.title': "Ce n'est pas un projet Flutter",
    'error.notFlutter.fix':
        "Lancez la commande dans le dossier d'une app Flutter, ou passez "
            '--path <dossier>.',
    'error.manifest.title': 'Fichier du projet illisible',
    'error.manifest.fix':
        'Corrigez le fichier pour que `flutter pub get` l’accepte, puis '
            'recommencez.',
    'error.release.title': 'Version de Flutter inconnue',
    'error.release.fix':
        'Utilisez une version publiée (ex. 3.44.9), une mineure (3.44), '
            '`stable`, `beta` ou `latest`.',
    'error.offline.title': 'Indisponible hors ligne',
    'error.offline.fix':
        'Lancez la commande une fois avec le réseau, ou retirez --offline.',
    'error.network.title': 'Erreur réseau',
    'error.network.fix':
        'Vérifiez la connexion ou le proxy, ou utilisez --offline avec les '
            'données en cache.',
    'error.sdk.title': 'SDK Flutter indisponible',
    'error.sdk.fix':
        "Consultez `upgrade-pilot doctor`, libérez de l'espace, puis "
            'recommencez.',
    'error.disk.title': 'Espace disque insuffisant',
    'error.disk.why': '{required} sont nécessaires, {available} sont libres.',
    'error.disk.fix':
        "Libérez de l'espace ou lancez `upgrade-pilot clean`, puis "
            'recommencez.',
    'error.noPlan.title': 'Aucun plan pour ce projet',
    'error.noPlan.fix': "Lancez d'abord `upgrade-pilot plan`.",
    'error.blockedPlan.title': 'Le dernier plan est bloqué',
    'error.blockedPlan.why': 'Seul un plan vérifié peut être appliqué.',
    'error.blockedPlan.fix':
        'Levez les blocages, puis relancez `upgrade-pilot plan`.',
    'error.emptyPlan.title': 'Rien à appliquer',
    'error.emptyPlan.why': 'Le plan vérifié ne contient aucune modification.',
    'error.emptyPlan.fix': "Suivez les étapes manuelles du plan, s'il y en a.",
    'error.changed.title': 'Le projet a changé depuis le plan',
    'error.changed.why':
        'Des fichiers couverts par le plan ont été modifiés après `plan`.',
    'error.changed.fix':
        "Relancez `upgrade-pilot plan` pour vérifier l'état actuel.",
    'error.dirty.title': 'Modifications non commitées',
    'error.dirty.why':
        'apply exige un dépôt git propre pour rester réversible.',
    'error.dirty.fix':
        'Commitez ou mettez de côté vos changements, ou passez --force.',
    'error.conflict.title': 'Fichier différent du plan',
    'error.conflict.why':
        '{path} ne correspond pas au contenu enregistré par le plan.',
    'error.conflict.fix': 'Relancez `upgrade-pilot plan`.',
    'error.noBackup.title': 'Aucune sauvegarde à restaurer',
    'error.noBackup.fix':
        'Les sauvegardes sont créées par `upgrade-pilot apply`.',
    'error.notConfirmed.title': 'Confirmation requise',
    'error.notConfirmed.why': "Le terminal n'est pas interactif.",
    'error.notConfirmed.fix': 'Passez --yes pour appliquer sans question.',
    'error.unknownFinding.title': 'Identifiant inconnu {id}',
    'error.unknownFinding.fix':
        'Utilisez un identifiant du dernier plan, ex. UP-AND-0007.',
    'error.kb.title': 'Base de compatibilité rejetée',
    'error.kb.fix': 'La base intégrée reste utilisée ; signalez le problème.',
    'error.interrupted.title': 'Interrompu',
    'error.interrupted.why': 'Ctrl+C reçu ; le bac à sable a été supprimé.',
    'error.interrupted.fix': 'Relancez la commande quand vous êtes prêt.',
    'error.internal.title': 'Erreur inattendue',
    'error.internal.fix': 'Relancez avec --verbose et signalez le problème.',
    'error.plan.title': 'Plan enregistré illisible',
    'error.plan.fix': 'Relancez `upgrade-pilot plan`.',
    'apply.confirm': 'Appliquer {changes} à {project} ? [o/N] ',
    'apply.done': '{changes} appliquées.',
    'apply.backup': 'Sauvegarde : {path}',
    'apply.revertHint': 'Annulez avec `upgrade-pilot apply --revert`.',
    'apply.reverted': '{count} fichiers restaurés depuis la sauvegarde.',
    'apply.cancelled': "Rien n'a été modifié.",
    'doctor.title': 'Environnement',
    'doctor.ok': 'Prêt pour planifier.',
    'doctor.missing': 'Un outil obligatoire manque.',
    'explain.cause': 'Cause',
    'explain.fix': 'Correctif',
    'explain.evidence': 'Preuve',
    'explain.confidence': 'Confiance',
    'explain.source': 'Source',
    'explain.noEvidence':
        'Absent du dernier plan ; description générale de la règle.',
    'report.written': 'Rapport écrit dans {path}',
    'kb.updated': 'Base de compatibilité mise à jour : {from} → {to}.',
    'kb.current': 'Base de compatibilité déjà à jour ({version}).',
    'clean.done.one': '{n} élément supprimé.',
    'clean.done.other': '{n} éléments supprimés.',
    'clean.nothing': 'Rien à nettoyer.',
    'confidence.high': 'haute',
    'confidence.medium': 'moyenne',
    'confidence.low': 'basse',
  };
}
