import 'dart:io';

import '../models/commit_model.dart';

class GitService {
  GitService();

  Future<Map<DateTime, List<CommitModel>>> fetchCommitsByDay({
    required String repoPath,
    required String author,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final normalizedStart = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
    );
    final normalizedEnd = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
      23,
      59,
      59,
    );

    final args = [
      'log',
      '--author=$author',
      '--since=${normalizedStart.toIso8601String()}',
      '--until=${normalizedEnd.toIso8601String()}',
      '--pretty=format:%H%x1f%an%x1f%ad%x1f%s',
      '--date=iso',
    ];

    final result = await Process.run('git', args, workingDirectory: repoPath);

    if (result.exitCode != 0) {
      final stderrText = (result.stderr ?? '').toString().trim();
      final message = stderrText.isEmpty
          ? 'Failed to run git log. Exit code: ${result.exitCode}'
          : stderrText;
      throw GitServiceException(message);
    }

    final stdoutText = (result.stdout ?? '').toString().trim();
    if (stdoutText.isEmpty) {
      return {};
    }

    final commits = stdoutText
        .split('\n')
        .map((line) => _parseCommitLine(line))
        .whereType<CommitModel>()
        .toList();

    final Map<DateTime, List<CommitModel>> grouped = {};
    for (final commit in commits) {
      final dayKey = DateTime(
        commit.date.year,
        commit.date.month,
        commit.date.day,
      );
      grouped.putIfAbsent(dayKey, () => []).add(commit);
    }
    return grouped;
  }

  CommitModel? _parseCommitLine(String line) {
    final parts = line.split('\x1f');
    if (parts.length < 4) {
      return null;
    }
    final hash = parts[0].trim();
    final author = parts[1].trim();
    final dateString = parts[2].trim();
    final message = parts[3].trim();
    final parsedDate = DateTime.tryParse(dateString);
    if (hash.isEmpty || message.isEmpty || parsedDate == null) {
      return null;
    }
    return CommitModel(
      hash: hash,
      message: message,
      date: parsedDate,
      author: author,
    );
  }
}

class GitServiceException implements Exception {
  GitServiceException(this.message);

  final String message;

  @override
  String toString() => 'GitServiceException: $message';
}
