from result_data import ResultData
from test_base import TestBase


class TestLogs(TestBase):
    def test_add_delete_member(self):
        self.db.execute("""INSERT INTO membres(cip, faculteID, departementID, nom, prenom) VALUES ('logs1234', 18, 08, 'leslogs', 'jaime')""")

        result = self.db.execute_fetch("""SELECT cip, numeropavillon, numerolocal, message FROM logs WHERE cip = 'logs1234'""")
        # ResultData.dump("test_add_delete_member", result)
        expected_result = ResultData.load("test_add_delete_member")

        self.assertEqual(expected_result, result)

    def test_add_reservation_log(self):
        self.db.execute("""INSERT INTO calendrier VALUES ('D7',3020,'2200-04-05','girp2705','toto',30,35)""")

        result = self.db.execute_fetch("""SELECT cip, numeropavillon, numerolocal, message FROM logs WHERE CIP = 'girp2705' AND numeropavillon = 'D7' AND numerolocal = 3020""")
        # ResultData.dump("test_logs_events", result)
        # print(result)
        expected_result = ResultData.load("test_logs_events")

        self.assertEqual(expected_result, result)
