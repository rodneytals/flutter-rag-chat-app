import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RagChatApp());
}

class RagChatApp extends StatelessWidget {
  const RagChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color.fromARGB(255, 36, 70, 170);

    return MaterialApp(
      title: 'RAG Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
        scaffoldBackgroundColor: const Color(0xFFF7F7FB),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          hintStyle: TextStyle(color: Colors.grey.shade600),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: const BorderSide(color: seedColor, width: 1.5),
          ),
        ),
      ),
      home: const ResponsiveChatScreen(),
    );
  }
}

class ResponsiveChatScreen extends StatefulWidget {
  const ResponsiveChatScreen({super.key});

  @override
  State<ResponsiveChatScreen> createState() => _ResponsiveChatScreenState();
}

class _ChatMessage {
  const _ChatMessage({
    required this.text,
    required this.fromUser,
    this.classification,
    this.retrievalSource,
    this.sources = const [],
    this.warning,
  });

  final String text;
  final bool fromUser;
  final String? classification;
  final String? retrievalSource;
  final List<ChatSource> sources;
  final String? warning;

  Map<String, dynamic> toJson() => {
        'text': text,
        'fromUser': fromUser,
        'classification': classification,
        'retrievalSource': retrievalSource,
        'warning': warning,
        'sources': sources
            .map((source) => {
                  'title': source.title,
                  'page': source.page,
                })
            .toList(),
      };

  factory _ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'] as List<dynamic>? ?? const [];
    return _ChatMessage(
      text: json['text']?.toString() ?? '',
      fromUser: json['fromUser'] == true,
      classification: json['classification']?.toString(),
      retrievalSource: json['retrievalSource']?.toString(),
      warning: json['warning']?.toString(),
      sources: rawSources
          .whereType<Map<String, dynamic>>()
          .map(ChatSource.fromJson)
          .toList(growable: false),
    );
  }
}

class _SavedConversation {
  const _SavedConversation({
    required this.id,
    required this.sessionId,
    required this.title,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  final String sessionId;
  final String title;
  final int updatedAt;
  final List<_ChatMessage> messages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'title': title,
        'updatedAt': updatedAt,
        'messages': messages.map((message) => message.toJson()).toList(),
      };

  factory _SavedConversation.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'] as List<dynamic>? ?? const [];
    return _SavedConversation(
      id: json['id']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Conversation',
      updatedAt: json['updatedAt'] as int? ?? 0,
      messages: rawMessages
          .whereType<Map<String, dynamic>>()
          .map(_ChatMessage.fromJson)
          .toList(growable: false),
    );
  }
}

class _ResponsiveChatScreenState extends State<ResponsiveChatScreen> {
  static const _desktopBreakpoint = 800.0;
  static const _requestTimeout = Duration(seconds: 65);
  static const _historyStorageKey = 'rag_chat_history_v1';
  static const _maxSavedConversations = 30;

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _chatService = ChatService();
  final List<_ChatMessage> _messages = [];
  final List<_SavedConversation> _conversations = [];
  String? _sessionId;
  String? _activeConversationId;
  bool _historyLoaded = false;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _loadConversationHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage([String? suggestedPrompt]) async {
    final question = (suggestedPrompt ?? _controller.text).trim();
    if (question.isEmpty || _isSending || !_historyLoaded) return;

    _sessionId ??= 'chat_${DateTime.now().microsecondsSinceEpoch}';
    _activeConversationId ??= _sessionId;

    setState(() {
      _messages.add(_ChatMessage(text: question, fromUser: true));
      _isSending = true;
      _controller.clear();
    });
    _scrollToLatest();
    unawaited(_saveActiveConversation());

    try {
      final response = await _chatService
          .sendMessage(question, sessionId: _sessionId)
          .timeout(_requestTimeout);
      if (!mounted) return;
      setState(() {
        _sessionId = response.sessionId.isEmpty ? _sessionId : response.sessionId;
        _messages.add(
          _ChatMessage(
            text: response.answer,
            fromUser: false,
            classification: response.classification,
            retrievalSource: response.retrievalSource,
            sources: response.sources,
            warning: response.warning,
          ),
        );
      });
      unawaited(_saveActiveConversation());
    } on TimeoutException {
      _addErrorMessage(
        'The server took too long to respond. Please check your connection and try again.',
      );
      unawaited(_saveActiveConversation());
    } catch (_) {
      _addErrorMessage(
        'I couldn’t reach the RAG server. Check that the server is running and try again.',
      );
      unawaited(_saveActiveConversation());
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToLatest();
      }
    }
  }

  void _addErrorMessage(String message) {
    if (!mounted) return;
    setState(() => _messages.add(_ChatMessage(text: message, fromUser: false)));
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _startNewChat() {
    if (_isSending || !_historyLoaded) return;
    setState(() {
      _activeConversationId = null;
      _sessionId = null;
      _messages.clear();
    });
    Navigator.of(context).maybePop();
  }

  Future<void> _loadConversationHistory() async {
    try {
      final saved = await _preferences.getString(_historyStorageKey);
      if (saved != null && saved.isNotEmpty) {
        final decoded = jsonDecode(saved) as List<dynamic>;
        final loaded = decoded
            .whereType<Map<String, dynamic>>()
            .map(_SavedConversation.fromJson)
            .where((conversation) =>
                conversation.id.isNotEmpty && conversation.messages.isNotEmpty)
            .toList();
        loaded.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        if (mounted) {
          setState(() {
            _conversations
              ..clear()
              ..addAll(loaded.take(_maxSavedConversations));
          });
        }
      }
    } catch (_) {
      // A damaged local history should not prevent the assistant from opening.
    } finally {
      if (mounted) setState(() => _historyLoaded = true);
    }
  }

  Future<void> _saveActiveConversation() async {
    final id = _activeConversationId;
    final sessionId = _sessionId;
    if (!_historyLoaded || id == null || sessionId == null || _messages.isEmpty) {
      return;
    }

    final firstQuestion = _messages.firstWhere(
      (message) => message.fromUser,
      orElse: () => _messages.first,
    ).text;
    final title = firstQuestion.length > 42
        ? '${firstQuestion.substring(0, 42)}…'
        : firstQuestion;
    final conversation = _SavedConversation(
      id: id,
      sessionId: sessionId,
      title: title.isEmpty ? 'Conversation' : title,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      messages: List<_ChatMessage>.unmodifiable(_messages),
    );

    if (mounted) {
      setState(() {
        _conversations.removeWhere((item) => item.id == id);
        _conversations.insert(0, conversation);
        if (_conversations.length > _maxSavedConversations) {
          _conversations.removeRange(
            _maxSavedConversations,
            _conversations.length,
          );
        }
      });
    }

    try {
      await _preferences.setString(
        _historyStorageKey,
        jsonEncode(_conversations.map((item) => item.toJson()).toList()),
      );
    } catch (_) {
      // Keep the live chat usable if local storage is unavailable.
    }
  }

  void _openConversation(_SavedConversation conversation) {
    if (_isSending) return;
    setState(() {
      _activeConversationId = conversation.id;
      _sessionId = conversation.sessionId;
      _messages
        ..clear()
        ..addAll(conversation.messages);
    });
    Navigator.of(context).maybePop();
    _scrollToLatest();
  }

  Future<void> _deleteConversation(_SavedConversation conversation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete saved chat?'),
        content: const Text('This removes the conversation from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _isSending) return;

    setState(() {
      _conversations.removeWhere((item) => item.id == conversation.id);
      if (_activeConversationId == conversation.id) {
        _activeConversationId = null;
        _sessionId = null;
        _messages.clear();
      }
    });
    try {
      await _preferences.setString(
        _historyStorageKey,
        jsonEncode(_conversations.map((item) => item.toJson()).toList()),
      );
    } catch (_) {
      // Keep the app usable if local storage is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= _desktopBreakpoint;

    return Scaffold(
      appBar: isDesktop
          ? null
          : AppBar(
              title: const Text('RAG Assistant'),
              centerTitle: false,
              actions: [
                IconButton(
                  tooltip: 'New chat',
                  onPressed: _startNewChat,
                  icon: const Icon(Icons.add_comment_outlined),
                ),
              ],
            ),
      drawer: isDesktop
          ? null
          : Drawer(
              child: SafeArea(
                child: _buildSidebar(isDrawer: true),
              ),
            ),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        top: isDesktop,
        child: isDesktop
            ? Row(
                children: [
                  SizedBox(width: 270, child: _buildSidebar()),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(child: _buildChatArea(isDesktop: true)),
                ],
              )
            : _buildChatArea(isDesktop: false),
      ),
    );
  }

  Widget _buildSidebar({bool isDrawer = false}) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  Icons.auto_awesome,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'RAG Assistant',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          FilledButton.icon(
            onPressed: _startNewChat,
            icon: const Icon(Icons.add),
            label: const Text('New chat'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.centerLeft,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'YOUR ASSISTANT',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F7FB),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.search_rounded,
                    size: 19, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Ask questions about your connected knowledge base.',
                    style: TextStyle(height: 1.4, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'RECENT CHATS',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildConversationList()),
          if (!isDrawer)
            Text(
              'Answers are generated from your RAG knowledge base.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildConversationList() {
    if (!_historyLoaded) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_conversations.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Your saved conversations will appear here.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _conversations.length,
      itemBuilder: (context, index) {
        final conversation = _conversations[index];
        final selected = conversation.id == _activeConversationId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: selected ? const Color(0xFFF0EFFA) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              dense: true,
              visualDensity: const VisualDensity(vertical: -2),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              leading: Icon(
                Icons.chat_bubble_outline_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(
                conversation.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                _conversationDate(conversation.updatedAt),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              trailing: IconButton(
                tooltip: 'Delete saved chat',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _isSending
                    ? null
                    : () => _deleteConversation(conversation),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
              onTap: () => _openConversation(conversation),
            ),
          ),
        );
      },
    );
  }

  String _conversationDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return 'Today';
    }
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$day/$month/${date.year}';
  }

  Widget _buildChatArea({required bool isDesktop}) {
    return Column(
      children: [
        if (isDesktop)
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFE9E9EF))),
            ),
            child: Text(
              _messages.isEmpty ? 'New conversation' : 'Conversation',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: _messages.isEmpty
                  ? _buildWelcome(isDesktop: isDesktop)
                  : _buildMessageList(isDesktop: isDesktop),
            ),
          ),
        ),
        _buildComposer(isDesktop: isDesktop),
      ],
    );
  }

  Widget _buildWelcome({required bool isDesktop}) {
    final prompts = [
      'What information is available in this knowledge base?',
      'Summarize the most important topics in my documents.',
    ];

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(isDesktop ? 32 : 22, 28, isDesktop ? 32 : 22, 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(Icons.auto_awesome,
                color: Theme.of(context).colorScheme.primary, size: 27),
          ),
          const SizedBox(height: 22),
          Text(
            'What would you like to know?',
            style: TextStyle(
              fontSize: isDesktop ? 30 : 25,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Ask a question and I’ll look for an answer in your knowledge base.',
            style: TextStyle(color: Colors.grey.shade700, height: 1.5),
          ),
          const SizedBox(height: 26),
          ...prompts.map(
            (prompt) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(15),
                  onTap: _isSending ? null : () => _sendMessage(prompt),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: const Color(0xFFE6E6EF)),
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(prompt)),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_outward, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList({required bool isDesktop}) {
    return ListView.builder(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(isDesktop ? 32 : 18, 24, isDesktop ? 32 : 18, 24),
      itemCount: _messages.length + (_isSending ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length) return const _TypingIndicator();
        final message = _messages[index];
        return _MessageBubble(message: message);
      },
    );
  }

  Widget _buildComposer({required bool isDesktop}) {
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        color: Colors.white,
        padding: EdgeInsets.fromLTRB(isDesktop ? 28 : 12, 12, isDesktop ? 28 : 12, 10),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: isDesktop ? 5 : 4,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: isDesktop
                        ? TextInputAction.newline
                        : TextInputAction.send,
                    onSubmitted: isDesktop ? null : (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: 'Ask a question…',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                SizedBox(
                  height: 52,
                  width: 52,
                  child: FilledButton(
                    onPressed: _isSending ? null : _sendMessage,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(17),
                      ),
                    ),
                    child: _isSending
                        ? const SizedBox(
                            width: 19,
                            height: 19,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.arrow_upward_rounded),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final _ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.fromUser;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 17,
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(Icons.auto_awesome,
                  size: 17, color: colorScheme.primary),
            ),
            const SizedBox(width: 9),
          ],
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 680),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                color: isUser ? colorScheme.primary : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isUser ? 18 : 5),
                  bottomRight: Radius.circular(isUser ? 5 : 18),
                ),
                border: isUser ? null : Border.all(color: const Color(0xFFE9E9EF)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isUser)
                    SelectableText(
                      message.text,
                      style: const TextStyle(color: Colors.white, height: 1.5),
                    )
                  else
                    MarkdownBody(
                      data: message.text,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                          .copyWith(
                        p: const TextStyle(
                          color: Color(0xFF24242B),
                          height: 1.5,
                        ),
                      ),
                    ),
                  if (!isUser && message.sources.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 9),
                    Text('Sources',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        )),
                    const SizedBox(height: 5),
                    ...message.sources.map((source) => Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.description_outlined,
                                  size: 15, color: colorScheme.primary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  source.page == null
                                      ? source.title
                                      : '${source.title} · page ${source.page}',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )),
                  ],
                  if (!isUser && (message.warning?.isNotEmpty ?? false)) ...[
                    const SizedBox(height: 8),
                    Text(message.warning!,
                        style: TextStyle(
                          color: Colors.orange.shade900,
                          fontSize: 12,
                        )),
                  ],
                  if (!isUser &&
                      ((message.classification?.isNotEmpty ?? false) ||
                          (message.retrievalSource?.isNotEmpty ?? false))) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (message.classification?.isNotEmpty ?? false)
                          _MetadataChip(label: message.classification!),
                        if (message.retrievalSource?.isNotEmpty ?? false)
                          _MetadataChip(label: message.retrievalSource!),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 26),
        ],
      ),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF0EFFA),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(Icons.auto_awesome,
              size: 17, color: Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(width: 10),
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text('Searching your knowledge base…',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
      ],
    );
  }
}
