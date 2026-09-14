import unittest
from fork_scope import allowed,FILES
class ForkScope(unittest.TestCase):
    def test_exact(self):self.assertTrue(allowed('TheNeuralCube/OB1','TheNeuralCube/OB1','feat/ob1-hub-mods',FILES))
    def test_rejects(self):
        for repo,head,branch,files in [
            ('NateBJones-Projects/OB1','TheNeuralCube/OB1','feat/ob1-hub-mods',FILES),
            ('TheNeuralCube/OB1','other/OB1','feat/ob1-hub-mods',FILES),
            ('TheNeuralCube/OB1','TheNeuralCube/OB1','other',FILES),
            ('TheNeuralCube/OB1','TheNeuralCube/OB1','feat/ob1-hub-mods',FILES|{'server/other.ts'}),
            ('TheNeuralCube/OB1','TheNeuralCube/OB1','feat/ob1-hub-mods',FILES-{'server/census.test.ts'})]:
            with self.subTest(repo=repo,branch=branch,files=files):self.assertFalse(allowed(repo,head,branch,files))
if __name__=='__main__':unittest.main()
