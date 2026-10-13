import pytest

from ghost_agentd.policy import L0, L1, L2, L3, ProjectPolicy, grade, grade_bash, suggest_pattern

POL = ProjectPolicy(root_paths=["/Users/me/projects/fq"])


@pytest.mark.parametrize("cmd,level", [
    ("ls -la", L0),
    ("git status", L0),
    ("git log --oneline -5", L0),
    ("git diff HEAD~1 -- src", L0),
    ("cat a.txt | grep foo | wc -l", L0),
    ("zig build test -Dtest-filter=x", L0),
    ("find . -name '*.py'", L0),
    ("sed -n 1,20p file", L0),
    ("git add -A && git commit -m 'x'", L1),
    ("echo hi > out.txt", L1),
    ("git push origin feature/okx-link", L2),
    ("rm -rf dist/", L2),
    ("npm install left-pad", L2),
    ("find . -name '*.tmp' -delete", L2),
    ("sed -i '' s/a/b/ f", L2),
    ("some-unknown-tool --do-it", L2),
    ("ls $(cat x)", L2),
    ("mysql -h test-db -e 'select 1'", L2),
    ("mysql -h prod-db -e 'UPDATE merchant SET x=1'", L3),
    ("walle 發 bc-pay 正式", L3),
    ("git push --force origin main", L3),
    ("sudo rm /etc/hosts", L3),
    ("ls && rm -rf /", L3),
])
def test_bash_levels(cmd, level):
    assert grade_bash(cmd, POL).level == level, grade_bash(cmd, POL)


def test_suggest_pattern_generalises_branch():
    assert suggest_pattern("git push origin feature/okx-link") == "git push origin feature/*"
    assert suggest_pattern("rm -rf dist/") == "rm -rf dist/*"
    assert suggest_pattern("npm install left-pad") == "npm install left-pad"
    assert suggest_pattern("rm $(x)") is None


def test_always_allow_lowers_l2_to_l1_but_never_l3():
    pol = ProjectPolicy(allow=["git push origin feature/*", "mysql *"])
    assert grade_bash("git push origin feature/abc", pol).level == L1
    assert grade_bash("git push origin main", pol).level == L2
    assert grade_bash("mysql -h prod-db -e 'x'", pol).level == L3


def test_project_overrides():
    pol = ProjectPolicy(l1=["walle 發 *-test"], l3=[r"bc-pay.*(INSERT|UPDATE|DELETE)"],
                        deny=["git commit *"])
    assert grade_bash("walle 發 bc-api-test", pol).level == L1
    assert grade_bash("echo 'bc-pay UPDATE x'", pol).level == L3
    assert grade_bash("git commit -m x", pol).level == L2


def test_file_tools():
    assert grade("Edit", {"file_path": "/Users/me/projects/fq/a.php"}, "/Users/me/projects/fq", POL).level == L0
    assert grade("Write", {"file_path": "/etc/hosts"}, "/Users/me/projects/fq", POL).level == L2
    assert grade("Edit", {"file_path": "/Users/me/projects/fq/.env"}, "/x", POL).level == L2
    assert grade("Read", {"file_path": "/Users/me/.ssh/id_rsa"}, "/x", POL).level == L2
    assert grade("Read", {"file_path": "/tmp/x"}, "/x", POL).level == L0


def test_mcp_tools():
    assert grade("mcp__claude_ai_ClickUp__clickup_get_task", {}, "", POL).level == L0
    assert grade("mcp__claude_ai_ClickUp__clickup_update_task", {}, "", POL).level == L2
    assert grade("mcp__claude_ai_Gmail__trash_thread", {}, "", POL).level == L2
