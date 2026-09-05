import '../core/models.dart';
import 'settings_store.dart';

/// Result ranks for [searchConversations]: a title hit outranks a
/// first-user-message hit; within a rank, most recently updated wins.
const _titleRank = 0;
const _contentRank = 1;

/// Searches the persisted conversation history.
///
/// A blank [query] returns every conversation in history order (pinned
/// first, then most recently updated) with no [limit] applied, so callers
/// can use it as the unfiltered view. A non-blank query matches
/// case-insensitively against the conversation title and the text of the
/// conversation's first user message (loaded from the checkpoint), ranks
/// title matches above content matches, orders most-recently-updated
/// first inside each rank, and returns at most [limit] results.
List<ConversationSummary> searchConversations(
  SettingsStore store,
  String query, {
  int limit = 20,
}) {
  final conversations = sortConversations(store.loadConversations());
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return conversations;

  // rank → pinned → recency ordering across all matches.
  final matches = <({ConversationSummary summary, int rank})>[];
  for (final conversation in conversations) {
    final titleHit = conversation.title.toLowerCase().contains(needle);
    final contentHit =
        !titleHit &&
        _firstUserText(store, conversation.id).toLowerCase().contains(needle);
    if (titleHit || contentHit) {
      matches.add((
        summary: conversation,
        rank: titleHit ? _titleRank : _contentRank,
      ));
    }
  }
  matches.sort((a, b) {
    if (a.rank != b.rank) return a.rank - b.rank;
    return b.summary.updatedAt.compareTo(a.summary.updatedAt);
  });
  return [for (final match in matches.take(limit)) match.summary];
}

/// Text of the conversation's first user message, or '' when the
/// checkpoint is missing/corrupt or has no user turn.
String _firstUserText(SettingsStore store, String conversationId) {
  final checkpoint = store.loadCheckpoint(conversationId);
  if (checkpoint == null) return '';
  for (final message in checkpoint.messages) {
    if (message.role == MessageRole.user) return message.content;
  }
  return '';
}
