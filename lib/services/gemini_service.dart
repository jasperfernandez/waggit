import 'package:google_generative_ai/google_generative_ai.dart';

class GeminiService {
  GeminiService({required String apiKey})
    : _model = GenerativeModel(model: 'gemini-2.5-flash-lite', apiKey: apiKey);

  final GenerativeModel _model;

  Future<List<String>> summarizeDay({
    required String dateLabel,
    required List<String> commitMessages,
  }) async {
    if (commitMessages.isEmpty) {
      return [];
    }

    final prompt = _buildPrompt(dateLabel, commitMessages);

    final response = await _model.generateContent([Content.text(prompt)]);

    final text = response.text?.trim() ?? '';
    if (text.isEmpty) {
      throw GeminiServiceException('Gemini API returned an empty response.');
    }

    return _extractBullets(text);
  }

  String _buildPrompt(String dateLabel, List<String> commitMessages) {
    final buffer = StringBuffer();
    buffer.writeln(
      'You are summarizing git commit messages into daily accomplishments.',
    );
    buffer.writeln('Date: $dateLabel');
    buffer.writeln('Provide 4-6 concise bullet points.');
    buffer.writeln(
      'Use action-oriented language, avoid repeating commit text.',
    );
    buffer.writeln(
      'Return only bullet points, one per line, prefixed with "- ".',
    );
    buffer.writeln('Commit messages:');
    for (final message in commitMessages) {
      buffer.writeln('- $message');
    }
    return buffer.toString();
  }

  List<String> _extractBullets(String text) {
    final lines = text.split('\n');
    final bullets = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final normalized = trimmed.startsWith('- ')
          ? trimmed.substring(2).trim()
          : trimmed.replaceFirst(RegExp(r'^[*•]\s+'), '').trim();
      if (normalized.isNotEmpty) {
        bullets.add(normalized);
      }
    }
    if (bullets.length < 4) {
      throw GeminiServiceException(
        'Gemini API returned fewer than 4 bullet points.',
      );
    }
    return bullets.take(6).toList();
  }
}

class GeminiServiceException implements Exception {
  GeminiServiceException(this.message);

  final String message;

  @override
  String toString() => 'GeminiServiceException: $message';
}
