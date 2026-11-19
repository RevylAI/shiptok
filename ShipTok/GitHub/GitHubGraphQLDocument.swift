enum GitHubGraphQLDocument {
    private static let issueCommentFieldsFragment = """
        fragment ShipTokIssueCommentFields on IssueComment {
          id
          databaseId
          author { __typename login avatarUrl }
          body
          bodyHTML
          createdAt
          lastEditedAt
          url
          viewerCanDelete
          reactionGroups { content viewerHasReacted reactors { totalCount } }
        }
        """

    private static let pullRequestFieldsFragment = """
        fragment ShipTokPullRequestFields on PullRequest {
          id
          number
          title
          url
          state
          isDraft
          updatedAt
          mergedAt
          createdAt
          lastEditedAt
          body
          bodyHTML
          additions
          deletions
          changedFiles
          labels(first: 20) { nodes { name color } }
          author { __typename login avatarUrl }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { ...ShipTokIssueCommentFields }
          }
        }
        """

    static let mergedPullRequestsMatchingSearchQuery = """
        query MergedPullRequestsMatchingSearch($searchQuery: String!, $after: String) {
          search(query: $searchQuery, type: ISSUE, first: 25, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest { ...ShipTokPullRequestFields } }
          }
        }
        """ + "\n" + pullRequestFieldsFragment + "\n" + issueCommentFieldsFragment

    static let pullRequestByNumberQuery = """
        query PullRequestByNumber($owner: String!, $name: String!, $number: Int!) {
          feedRepository: repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { ...ShipTokPullRequestFields }
          }
        }
        """ + "\n" + pullRequestFieldsFragment + "\n" + issueCommentFieldsFragment

    static let commentsPageQuery = """
        query CommentsPage($subjectID: ID!, $after: String!) {
          node(id: $subjectID) {
            ... on PullRequest {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { ...ShipTokIssueCommentFields }
              }
            }
            ... on Issue {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { ...ShipTokIssueCommentFields }
              }
            }
          }
        }
        """ + "\n" + issueCommentFieldsFragment

    private static let weeklyEditionFieldsFragment = """
        fragment ShipTokWeeklyEditionFields on Issue {
          id
          number
          url
          state
          labels(first: 100) { nodes { name color } }
          createdAt
          lastEditedAt
          body
          bodyHTML
          author { __typename login avatarUrl }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { ...ShipTokIssueCommentFields }
          }
        }
        """

    static let closedWeeklyEditionIssuesQuery = """
        query ClosedWeeklyEditionIssues($owner: String!, $name: String!, $labelName: String!, $after: String) {
          feedRepository: repository(owner: $owner, name: $name) {
            issues(labels: [$labelName], states: [CLOSED], first: 25, after: $after, orderBy: { field: CREATED_AT, direction: DESC }) {
              pageInfo { hasNextPage endCursor }
              nodes { ...ShipTokWeeklyEditionFields }
            }
          }
        }
        """ + "\n" + weeklyEditionFieldsFragment + "\n" + issueCommentFieldsFragment

    static let weeklyEditionByNumberQuery = """
        query WeeklyEditionByNumber($owner: String!, $name: String!, $number: Int!) {
          feedRepository: repository(owner: $owner, name: $name) {
            issue(number: $number) { ...ShipTokWeeklyEditionFields }
          }
        }
        """ + "\n" + weeklyEditionFieldsFragment + "\n" + issueCommentFieldsFragment

    static let mergedPullRequestSearchProbeQuery = """
        query MergedPullRequestSearchProbe($owner: String!, $name: String!, $searchQuery: String!) {
          feedRepository: repository(owner: $owner, name: $name) { createdAt }
          search(query: $searchQuery, type: ISSUE, first: 0) { issueCount }
        }
        """

    static let addPullRequestCommentMutation = """
        mutation AddPullRequestComment($subjectID: ID!, $body: String!) {
          addComment(input: {subjectId: $subjectID, body: $body}) {
            commentEdge { node { ...ShipTokIssueCommentFields } }
          }
        }
        """ + "\n" + issueCommentFieldsFragment

    static let deletePullRequestCommentMutation = """
        mutation DeletePullRequestComment($commentID: ID!) {
          deleteIssueComment(input: {id: $commentID}) { clientMutationId }
        }
        """

    static let addReactionMutation = """
        mutation AddReaction($subjectID: ID!, $content: ReactionContent!) {
          addReaction(input: {subjectId: $subjectID, content: $content}) { reaction { content } }
        }
        """

    static let removeReactionMutation = """
        mutation RemoveReaction($subjectID: ID!, $content: ReactionContent!) {
          removeReaction(input: {subjectId: $subjectID, content: $content}) { reaction { content } }
        }
        """
}
