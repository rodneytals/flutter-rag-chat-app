import 'dart:convert';

import 'package:http/http.dart' as http;

class ChatSource {
  final String title;
  final String? page;

  const ChatSource({required this.title, this.page});

  factory ChatSource.fromJson(Map<String, dynamic> json) {
    return ChatSource(
      title: json['title']?.toString() ?? 'Source document',
      page: json['page']?.toString(),
    );
  }
}

class ChatResponse {
  final String answer;
  final String sessionId;
  final String classification;
  final String retrievalSource;
  final String reviewerVerdict;
  final String? warning;
  final List<ChatSource> sources;

  const ChatResponse({
    required this.answer,
    required this.sessionId,
    required this.classification,
    required this.retrievalSource,
    required this.reviewerVerdict,
    required this.warning,
    required this.sources,
  });

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'] as List<dynamic>? ?? const [];

    return ChatResponse(
      answer: json['answer']?.toString() ?? 'No answer provided.',
      sessionId: json['session_id']?.toString() ?? '',
      classification: json['classification']?.toString() ?? 'UNKNOWN',
      retrievalSource: json['retrieval_source']?.toString() ?? 'none',
      reviewerVerdict: json['reviewer_verdict']?.toString() ?? '',
      warning: json['warning']?.toString(),
      sources: rawSources
          .whereType<Map<String, dynamic>>()
          .map(ChatSource.fromJson)
          .toList(growable: false),
    );
  }
}

class ChatService {
  // Update this if your Cloudflare quick-tunnel address has changed.
  static const String endpointUrl =
      'https://sticks-jesse-delivery-logging.trycloudflare.com/ask';

  // Replace this placeholder locally. Do not share the key in chat.
  static const String apiKey = 'dakmrFUmxJFF8bri11WAi6uLXFtsBMbd';

  Future<ChatResponse> sendMessage(
    String question, {
    String? sessionId,
  }) async {
    try {
      final requestBody = <String, dynamic>{
        'question': question,
        if (sessionId != null && sessionId.isNotEmpty)
          'session_id': sessionId,
      };

      final response = await http.post(
        Uri.parse(endpointUrl),
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': apiKey,
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Unexpected response from the RAG server.');
        }

        return ChatResponse.fromJson(decoded);
      }

      throw Exception(
        'Server error (${response.statusCode}): ${response.body}',
      );
    } catch (error) {
      throw Exception('Failed to connect to the RAG backend: $error');
    }
  }
}