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

    static let openPullRequestsPageQuery = """
        query OpenPullRequestsPage($owner: String!, $name: String!, $after: String) {
          feedRepository: repository(owner: $owner, name: $name) {
            pullRequests(states: [OPEN], first: 25, after: $after, orderBy: { field: UPDATED_AT, direction: DESC }) {
              pageInfo { hasNextPage endCursor }
              nodes { ...ShipTokPullRequestFields }
            }
          }
        }
        """ + "\n" + pullRequestFieldsFragment + "\n" + issueCommentFieldsFragment

    static let pullRequestUpdatesQuery = """
        query PullRequestUpdates($owner: String!, $name: String!, $states: [PullRequestState!]!, $after: String) {
          feedRepository: repository(owner: $owner, name: $name) {
            pullRequests(states: $states, first: 50, after: $after, orderBy: { field: UPDATED_AT, direction: DESC }) {
              pageInfo { hasNextPage endCursor }
              nodes { id updatedAt mergedAt }
            }
          }
        }
        """

    static let pullRequestsByIDQuery = """
        query PullRequestsByID($ids: [ID!]!) {
          nodes(ids: $ids) { ... on PullRequest { ...ShipTokPullRequestFields } }
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

    private static let issueFieldsFragment = """
        fragment ShipTokIssueFields on Issue {
          id
          number
          url
          state
          labels(first: 100) { nodes { name color } }
          createdAt
          closedAt
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

    static let closedIssuesWithLabelQuery = """
        query ClosedIssuesWithLabel($owner: String!, $name: String!, $labelName: String!, $after: String) {
          feedRepository: repository(owner: $owner, name: $name) {
            issues(labels: [$labelName], states: [CLOSED], first: 25, after: $after, orderBy: { field: CREATED_AT, direction: DESC }) {
              pageInfo { hasNextPage endCursor }
              nodes { ...ShipTokIssueFields }
            }
          }
        }
        """ + "\n" + issueFieldsFragment + "\n" + issueCommentFieldsFragment

    static let issueByNumberQuery = """
        query IssueByNumber($owner: String!, $name: String!, $number: Int!) {
          feedRepository: repository(owner: $owner, name: $name) {
            issue(number: $number) { ...ShipTokIssueFields }
          }
        }
        """ + "\n" + issueFieldsFragment + "\n" + issueCommentFieldsFragment

    static let mergedPullRequestSearchProbeQuery = """
        query MergedPullRequestSearchProbe($owner: String!, $name: String!, $searchQuery: String!) {
          feedRepository: repository(owner: $owner, name: $name) { createdAt }
          search(query: $searchQuery, type: ISSUE, first: 0) { issueCount }
        }
        """

    // One count per search, answered together, so a merged page picks its merge-date window in a single request.
    static func mergedPullRequestCountsQuery(searchQueryCount: Int) -> String {
        let variableDefinitions = (0..<searchQueryCount).map { "$searchQuery\($0): String!" }.joined(separator: ", ")
        let countFields = (0..<searchQueryCount).map { "  count\($0): search(query: $searchQuery\($0), type: ISSUE, first: 0) { issueCount }" }.joined(separator: "\n")
        return "query MergedPullRequestCounts(\(variableDefinitions)) {\n\(countFields)\n}"
    }

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
