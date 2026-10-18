import java.io.*;

public class Skip {
  public static void main(String[] a) throws Exception {
    File f = File.createTempFile("jskip", ".bin");
    try (FileOutputStream o = new FileOutputStream(f)) { o.write("0123456789".getBytes()); }
    System.out.println("file " + f);
    try (FileInputStream i = new FileInputStream(f)) {
      try { System.out.println("skip -> " + i.skip(Long.MAX_VALUE)); }
      catch (IOException e) { System.out.println("skip threw " + e.getClass().getName() + ": " + e.getMessage()); }
      try { System.out.println("read -> " + i.read()); }
      catch (IOException e) { System.out.println("read threw " + e.getClass().getName() + ": " + e.getMessage()); }
    } finally { f.delete(); }
  }
}
